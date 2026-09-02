{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    fenix,
    crane,
    flake-utils,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) lib;

        # Add the WASM target to Fenix for frontend compilation. Must be the
        # same channel as `stable.toolchain`/`stable.rust-src` below
        # (`latest` means nightly in fenix's channel naming) — otherwise the
        # wasm32 std/core/compiler_builtins are built by a different rustc
        # than the one doing the compiling, and every wasm32 build fails
        # with spurious "cannot find `Some`/`Option` in this scope" errors.
        wasmTarget = fenix.packages.${system}.targets.wasm32-unknown-unknown.stable.rust-std;

        rustToolchain = fenix.packages.${system}.combine [
          fenix.packages.${system}.stable.toolchain
          fenix.packages.${system}.stable.rust-src
          wasmTarget
        ];

        # Configure crane to use the Fenix toolchain
        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;
        src = craneLib.cleanCargoSource ./.;

        commonArgs = {
          inherit src;
          strictDeps = true;

          # `craneLib.buildPackage` runs `cargo test` by default between
          # build and install. Two things make that a non-starter in the
          # sandbox specifically (as opposed to just skipping real test
          # coverage -- both crates are fully covered by `cargo test`
          # run directly, network and all, outside of `nix build`):
          # web-server's tests need `libavutil.so` et al on
          # LD_LIBRARY_PATH (nix build's rpath-patching happens at
          # *install*, after this check would already have failed), and
          # both it and lib-db need a network-reachable
          # TEST_DATABASE_URL Postgres (see lib-db/src/db.rs's
          # `connect_in_memory` doc comment) -- sandboxed builds get no
          # network at all.
          doCheck = false;

          buildInputs = [];

          nativeBuildInputs = [
            pkgs.pkg-config
          ];
        };

        ffmpegArgs =
          commonArgs
          // {
            buildInputs =
              (commonArgs.buildInputs or [])
              ++ [
                pkgs.ffmpeg-headless
              ];

            nativeBuildInputs =
              (commonArgs.nativeBuildInputs or [])
              ++ [
                pkgs.llvmPackages.libclang.lib
              ];

            LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
            BINDGEN_EXTRA_CLANG_ARGS = "-isystem ${pkgs.glibc.dev}/include";
          };

        frontendArgs =
          commonArgs
          // {
            CARGO_BUILD_TARGET = "wasm32-unknown-unknown";
            # Without this, `buildDepsOnly` below vendors and compiles
            # deps for every workspace member under wasm32 — including
            # web-server's tokio (full reactor, i.e. mio), which doesn't
            # support wasm32-unknown-unknown at all and fails the build
            # before it ever gets to web-frontend's own (wasm-safe) deps.
            cargoExtraArgs = "-p web-frontend";

            buildInputs =
              (commonArgs.buildInputs or [])
              ++ [
                pkgs.openssl
              ];

            nativeBuildInputs =
              (commonArgs.nativeBuildInputs or [])
              ++ [
                pkgs.dioxus-cli
                # No pkgs.wasm-bindgen-cli here on purpose: on nixpkgs >=25.11,
                # dx bundles/manages its own wasm-bindgen matching the crate
                # version in Cargo.lock. A separately-installed
                # wasm-bindgen-cli shadows that and *causes* "Incorrect
                # wasm-bindgen-cli version" errors, since wasm-bindgen isn't
                # semver-compatible across patch releases (the ecosystem's
                # crates pin each other with exact `=` requirements).
                pkgs.binaryen # Provides wasm-opt
              ];
          };

        cargoArtifacts = craneLib.buildDepsOnly commonArgs;
        ffmpegCargoArtifacts = craneLib.buildDepsOnly ffmpegArgs;
        frontendCargoArtifacts = craneLib.buildDepsOnly frontendArgs;

        individualCrateArgs =
          commonArgs
          // {
            inherit cargoArtifacts;
            inherit (craneLib.crateNameFromCargoToml {inherit src;}) version;
          };

        ffmpegIndividualCrateArgs =
          ffmpegArgs
          // {
            cargoArtifacts = ffmpegCargoArtifacts;
            inherit (craneLib.crateNameFromCargoToml {inherit src;}) version;
          };

        frontendIndividualCrateArgs =
          frontendArgs
          // {
            cargoArtifacts = frontendCargoArtifacts;
            inherit (craneLib.crateNameFromCargoToml {inherit src;}) version;
          };

        fileSetForCrate = crate:
          lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./Cargo.toml
              ./Cargo.lock
              # Cargo resolves the whole workspace graph even when the
              # build itself is scoped with `-p` (cargoExtraArgs above),
              # so every member needs to parse as a real crate -- not
              # just have a readable Cargo.toml -- or it fails up front
              # with "no targets specified in the manifest" (Cargo's
              # src/main.rs-or-src/lib.rs auto-discovery finding
              # nothing). So both service crates' full sources are
              # included unconditionally, whichever one is actually being
              # built -- they're small, and it's simpler than hand-faking
              # a dummy src/main.rs for the one being left out.
              (craneLib.fileset.commonCargoSources ./crates/services)
              (craneLib.fileset.commonCargoSources ./crates/libs)
              # `commonCargoSources` only sweeps up Cargo.toml/*.rs --
              # lib-db's migrations/*.sql aren't Rust sources, but
              # `sqlx::migrate!("./migrations")` (db.rs) embeds them at
              # *compile* time, so the directory has to actually be
              # there or that macro fails with "error canonicalizing
              # migration directory".
              ./crates/libs/lib-db/migrations
              # Same story as the migrations dir above: dioxus's
              # `asset!("/assets/tailwind.css")` (app.rs) checks the file
              # actually exists at *compile* time, and `commonCargoSources`
              # doesn't know to sweep up a non-Rust assets/ directory.
              ./crates/services/web-frontend/assets
              # `dx build` (the `web-frontend` package below) reads this
              # HTML shell directly to produce the bundled site's
              # `index.html` -- also outside `commonCargoSources`'s
              # `Cargo.toml`/`*.rs` sweep. Without it, `dx build` silently
              # falls back to its own generic default index.html instead
              # of this project's.
              ./crates/services/web-frontend/index.html
              (craneLib.fileset.commonCargoSources ./crates/workspace-hackari)
              (craneLib.fileset.commonCargoSources crate)
            ];
          };

        web-server = craneLib.buildPackage (
          ffmpegIndividualCrateArgs
          // {
            pname = "web-server";
            cargoExtraArgs = "-p web-server";
            src = fileSetForCrate ./crates/services/web-server;
          }
        );

        # `craneLib.buildPackage` assumes `cargo build` + `cargo install`
        # semantics (copy the resulting binary out) -- fine for
        # `web-server`, wrong for a Dioxus web app: `cargo build`ing
        # web-frontend on its own only produces a bare .wasm, none of the
        # wasm-bindgen JS glue / index.html / hashed asset copies that
        # `dx build` bundles on top, which is what's actually servable.
        # `craneLib.mkCargoDerivation` (what crane's own `buildTrunkPackage`
        # uses for the equivalent trunk-based-wasm-frontend case) hands
        # full control of the build/install phases over instead, still
        # wired to the same offline-vendored `cargoArtifacts` dep cache.
        #
        # `API_BASE_URL` isn't set here -- left for whoever builds this
        # for a real deploy to override (e.g. via `.overrideAttrs`), same
        # env var `dx serve`/`dx build` read directly (see
        # web-frontend/src/api.rs's `api_base_url`). Unset, the built
        # bundle falls back to that function's own default
        # (`http://localhost:3001`), matching `web-server`'s dev default.
        web-frontend = craneLib.mkCargoDerivation (
          frontendIndividualCrateArgs
          // {
            pname = "web-frontend";
            src = fileSetForCrate ./crates/services/web-frontend;

            buildPhaseCargoCommand = "dx build --package web-frontend --release";
            installPhaseCommand = "cp -r target/dx/web-frontend/release/web/public $out";
            # `mkCargoDerivation` otherwise packs the whole `target/` dir
            # into `$out/target.tar.zst` by default, for reuse as another
            # derivation's `cargoArtifacts` -- nothing downstream chains
            # off this one, and it was ~150MB dead weight alongside the
            # actual (kilobytes-sized) site bundle `installPhaseCommand`
            # already put in `$out`.
            doInstallCargoArtifacts = false;
          }
        );
        # x86_64-linux/aarch64-linux only -- dockerTools has nothing to
        # build on Darwin. Native only for now: no cross-compiling
        # web-server (its ffmpegArgs need llvmPackages.libclang/glibc.dev
        # headers for the bindgen build script, which don't cross-build
        # for free) so this image targets whatever `system` it's built
        # on, not a fixed architecture.
        web-server-image = pkgs.dockerTools.buildLayeredImage {
          name = "web-server";
          tag = "latest";
          created = "now";

          # Just the closure `web-server` actually needs at runtime:
          # itself (already rpath-wrapped against ffmpeg-headless's libs
          # by `nix build`) plus a CA bundle for the outbound HTTPS calls
          # to Cloudflare's API (lib_cloudflare's reqwest) -- cheap
          # insurance whether or not the rustls build actually needed it
          # (see lib-cloudflare/Cargo.toml's reqwest features).
          contents = [pkgs.cacert web-server];

          config = {
            Cmd = ["${web-server}/bin/web-server"];
            # Writable at runtime (the container's overlay, not the R/O
            # nix store) -- `LOCAL_ASSETS_DIR` (default "data/assets",
            # relative to this) is `create_dir_all`'d on startup. Mount a
            # volume here to persist it across container recreates.
            WorkingDir = "/data";
            Env = ["SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"];
            ExposedPorts = {"3001/tcp" = {};};
          };
        };
      in {
        packages =
          {
            inherit web-server web-frontend;
            default = web-frontend;

            # Exposed so a manifests-only checkout (Cargo.toml/Cargo.lock/
            # flake.nix, no actual .rs sources -- see
            # next_file_browser-ci's sync-ci-deps.sh) can `nix build` just
            # the third-party dependency graph and push the result to
            # Cachix. `buildDepsOnly` doesn't read real crate source at
            # all -- crane substitutes dummy stub files internally -- so
            # this warms the (slow, non-proprietary) dependency cache
            # without any of this project's own code ever needing to
            # leave this machine.
            #
            # `ffmpegCargoArtifacts` covers the *whole* native workspace,
            # not just web-server: `ffmpegArgs` sets no `cargoExtraArgs`
            # scope, same as plain `commonArgs`/`cargoArtifacts` above,
            # just with the ffmpeg-headless headers `ffmpeg-sys-next`
            # (pulled in workspace-wide via lib-ffmpeg) needs to build at
            # all -- so it's a strict superset and there's no separate
            # "plain" deps output to build alongside it.
            cargo-deps-ffmpeg = ffmpegCargoArtifacts;
            cargo-deps-frontend = frontendCargoArtifacts;
          }
          // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            inherit web-server-image;
          };

        apps = {
          web-server = flake-utils.lib.mkApp {
            drv = web-server;
          };
          web-frontend = flake-utils.lib.mkApp {
            drv = web-frontend;
          };
        };

        devShells.default = craneLib.devShell {
          inputsFrom = [web-server web-frontend];

          LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
          BINDGEN_EXTRA_CLANG_ARGS = "-isystem ${pkgs.glibc.dev}/include";

          # `ffmpeg-headless` is a build input (via `ffmpegArgs`/`inputsFrom`
          # above) so `cargo build`/`check` links against it fine, but that
          # alone doesn't get its `libavutil.so` etc. onto the runtime
          # linker's search path — `nix build`'s wrapping would patch an
          # rpath in, but a plain `cargo test`/`cargo run` inside this
          # devShell doesn't go through that, and fails at process start
          # with "error while loading shared libraries: libavutil.so.NN".
          LD_LIBRARY_PATH = lib.makeLibraryPath [pkgs.ffmpeg-headless];

          shellHook = ''
            TOOLCHAIN_DIR="$HOME/.rust-rover/toolchain"

            # 1. Reset target path cleanly
            rm -rf "$TOOLCHAIN_DIR"

            # 2. Symlink entire combined Fenix toolchain directory for Rust Rover
            ln -sfn "${rustToolchain}" "$TOOLCHAIN_DIR"

            # 3. Standard source variable path pointing into Fenix output
            export RUST_SRC_PATH="${rustToolchain}/lib/rustlib/src/rust/library"

            # 4. Work around a RustRover/intellij-rust bug with Nix-provided
            # (read-only) toolchains: when it builds its local stdlib-source
            # cache under ~/.cache/JetBrains/<product>/intellij-rust/
            # stdlib-local-copy/<version>-<hash>/, it copies our (read-only,
            # store-owned) directory permissions onto each destination dir as
            # it creates it, before finishing writing that dir's children —
            # so it fails with AccessDeniedException partway through and
            # leaves an empty/partial dir behind, then reports "Corrupted
            # standard library". `cp -a` doesn't have this problem (it fixes
            # directory permissions in a final pass), so re-seed any such
            # dir ourselves whenever it's empty or not writable.
            for d in "$HOME"/.cache/JetBrains/*/intellij-rust/stdlib-local-copy/*/; do
              [ -d "$d" ] || continue
              if [ -z "$(ls -A "$d" 2>/dev/null)" ] || [ ! -w "$d" ]; then
                echo "next_file_browser: repairing RustRover stdlib cache at $d" >&2
                cp -a "$RUST_SRC_PATH"/. "$d" 2>/dev/null
                chmod -R u+w "$d" 2>/dev/null
              fi
            done
          '';

          packages = with pkgs; [
            cargo-hakari
            sqlx-cli
            dioxus-cli
            # wasm-bindgen-cli intentionally omitted — see the comment by
            # frontendArgs.nativeBuildInputs above.
            binaryen
            tailwindcss
          ];
        };
      }
    );
}