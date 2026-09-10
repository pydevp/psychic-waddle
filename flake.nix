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
            # lib-proto's build.rs (crates/libs/lib-proto/build.rs) shells
            # out to `protoc` to compile proto/*.proto for every svc-*
            # crate (and, transitively, web-server — see its Cargo.toml's
            # comment on why it depends on the svc-* crates directly) —
            # in commonArgs rather than just gstreamerArgs/web-server's own
            # args so `cargoArtifacts`/`buildDepsOnly` (which builds every
            # workspace member's deps, lib-proto included) has it too.
            pkgs.protobuf
          ];
        };

        # lib-gstreamer drives a GStreamer pipeline (demux/parse/mux via
        # `gstreamer`/`gstreamer-app`'s Rust bindings) -- previously bound
        # ffmpeg-next directly, hence `gstreamerArgs`/`gstreamerCargoArtifacts`
        # etc. below having once been `ffmpeg*`-named (see git history if
        # that naming still turns up anywhere unexpected).
        # `-base`/`-good` cover the elements the mux pipeline needs
        # (`parsebin`, `mpegtsmux`, `splitmuxsink`, `souphttpsrc`, `aacparse`,
        # `qtdemux`/`matroskademux`); `-bad` is required separately for
        # `h264parse`/`h265parse`, which nixpkgs ships there, not in `-good`.
        gstPackages = with pkgs.gst_all_1; [
          gstreamer
          gst-plugins-base
          gst-plugins-good
          gst-plugins-bad
          gst-plugins-rs
          # Not a GStreamer package itself, but gstreamer-rs's core types
          # (Object, Element, ...) are GObjects -- glib/gobject/gio's libs
          # are always a runtime dependency, just not one `nix build`'s
          # RPATH-patching needs help finding (transitive DT_NEEDED chains
          # resolve fine there); a plain `cargo build`/`test` binary here
          # has no RPATH at all, so it needs them on `LD_LIBRARY_PATH`
          # explicitly like everything else in this list (confirmed via
          # `ldd`: libgobject-2.0/libglib-2.0/libgio-2.0 all "not found"
          # without this).
          pkgs.glib
        ];

        gstreamerArgs =
          commonArgs
          // {
            buildInputs = (commonArgs.buildInputs or []) ++ gstPackages;

            # gstreamer-rs's `-sys` crates resolve against pkg-config, not
            # bindgen, so this pair is very likely dead weight now that
            # ffmpeg-sys-next (the thing that actually needed it) is gone --
            # left in rather than removed blind, since it's harmless to keep
            # and only costs anything if it's wrong.
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

        # `svc-assets`/`svc-download` (unlike `web-server`/`svc-transcode`)
        # never touch `lib-gstreamer`, so their own `buildDepsOnly` is scoped
        # with `cargoExtraArgs` the same way `frontendArgs` scopes
        # `web-frontend` below — without this, plain `commonArgs`
        # (no `cargoExtraArgs`) still resolves and *builds* the whole
        # workspace's dependency graph, `lib-gstreamer`'s gstreamer-sys/
        # glib-sys included, since they're real workspace members
        # regardless of which package a later `-p` targets — confirmed by
        # `svc-assets`/`svc-download` failing to build at all in a
        # from-scratch sandbox with no system `glib-2.0` (`pkg-config`)
        # once this crate had no other reason to bring `gstPackages` in
        # transitively via `cargoArtifacts`. Naming both packages in one
        # `cargoExtraArgs` (rather than a separate scope each) builds
        # their heavily-overlapping shared deps (tonic/prost/tokio/reqwest)
        # once instead of twice.
        svcLightArgs =
          commonArgs
          // {
            cargoExtraArgs = "-p svc-assets -p svc-download";
          };

        gstreamerCargoArtifacts = craneLib.buildDepsOnly gstreamerArgs;
        frontendCargoArtifacts = craneLib.buildDepsOnly frontendArgs;
        svcLightCargoArtifacts = craneLib.buildDepsOnly svcLightArgs;

        svcLightIndividualCrateArgs =
          commonArgs
          // {
            cargoArtifacts = svcLightCargoArtifacts;
            inherit (craneLib.crateNameFromCargoToml {inherit src;}) version;
          };

        gstreamerIndividualCrateArgs =
          gstreamerArgs
          // {
            cargoArtifacts = gstreamerCargoArtifacts;
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
              # Same story: lib-proto's build.rs shells out to `protoc`
              # against `proto/*.proto` at *compile* time (see
              # commonArgs.nativeBuildInputs's comment on that build.rs) --
              # `commonCargoSources` doesn't sweep up non-Rust files, so
              # without this every crate depending on lib-proto (i.e. every
              # svc-* service, and web-server transitively) fails to build
              # with "protoc failed: ... No such file or directory".
              ./crates/libs/lib-proto/proto
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
          gstreamerIndividualCrateArgs
          // {
            pname = "web-server";
            cargoExtraArgs = "-p web-server";
            src = fileSetForCrate ./crates/services/web-server;

            # Same split-output problem `ffmpeg-headless` used to have:
            # `gstreamerArgs.buildInputs` above pulls in each `gstPackages`
            # entry's `dev` output (headers + .pc files pkg-config needs to
            # *link*), but that alone puts nothing on the resulting binary's
            # RPATH and nothing in Nix's closure scan -- so a plain
            # `cargo`-built binary resolves `libgstreamer-1.0.so` et al only
            # by accident of the devShell's `LD_LIBRARY_PATH` (below), and
            # fails for real under `nix run`/the `web-server-image`
            # container. Explicitly listing each package's `.out` (its
            # runtime libs) plus running `autoPatchelfHook` (scoped to just
            # this derivation, same reasoning as the old ffmpeg-headless
            # comment here) patches a real RPATH in during fixupPhase and
            # gets these picked up as runtime closure dependencies too.
            buildInputs = gstreamerIndividualCrateArgs.buildInputs ++ map (p: p.out) gstPackages;
            nativeBuildInputs = gstreamerIndividualCrateArgs.nativeBuildInputs ++ [pkgs.autoPatchelfHook pkgs.makeWrapper];

            # RPATH (patched above) is enough for the binary to `dlopen`
            # libgstreamer-1.0.so itself, but GStreamer's *element* registry
            # (parsebin, mpegtsmux, splitmuxsink, souphttpsrc, ...) is found
            # by scanning `lib/gstreamer-1.0/` under `GST_PLUGIN_SYSTEM_PATH_1_0`
            # at runtime -- there's no FHS `/usr/lib/gstreamer-1.0` for it to
            # fall back to in the Nix store, so without this every pipeline
            # build fails with "no element ... found" however the binary is
            # invoked (bare `nix run`, or the `web-server-image` container).
            postFixup = ''
              wrapProgram $out/bin/web-server \
                --set GST_PLUGIN_SYSTEM_PATH_1_0 "${lib.concatMapStringsSep ":" (p: "${p.out}/lib/gstreamer-1.0") gstPackages}"
            '';
          }
        );

        # `svc-transcode`: the other GStreamer-linking binary (it *is* the
        # transcode backend web-server can point at over gRPC instead of
        # running `GstreamerTranscoder` in-process -- see
        # crates/services/GRPC_MIGRATION.md) -- same `gstreamerIndividualCrateArgs`/
        # RPATH-wrapping/`GST_PLUGIN_SYSTEM_PATH_1_0` story as `web-server`
        # above, just against this crate's own binary.
        svc-transcode = craneLib.buildPackage (
          gstreamerIndividualCrateArgs
          // {
            pname = "svc-transcode";
            cargoExtraArgs = "-p svc-transcode";
            src = fileSetForCrate ./crates/services/svc-transcode;

            buildInputs = gstreamerIndividualCrateArgs.buildInputs ++ map (p: p.out) gstPackages;
            nativeBuildInputs = gstreamerIndividualCrateArgs.nativeBuildInputs ++ [pkgs.autoPatchelfHook pkgs.makeWrapper];

            postFixup = ''
              wrapProgram $out/bin/svc-transcode \
                --set GST_PLUGIN_SYSTEM_PATH_1_0 "${lib.concatMapStringsSep ":" (p: "${p.out}/lib/gstreamer-1.0") gstPackages}"
            '';
          }
        );

        # `svc-assets`/`svc-download` link none of `lib-gstreamer`'s GStreamer
        # bindings (see crates/services/GRPC_MIGRATION.md's per-service
        # dependency table: `svc-assets` wraps `lib-storage`+`lib-cloudflare`
        # +`lib-db`, `svc-download` wraps `lib-download` -- reqwest/sqlx over
        # rustls, no native libs beyond glibc) -- built from
        # `svcLightIndividualCrateArgs` rather than `gstreamerIndividualCrateArgs`,
        # so neither one pulls in `gstPackages`, `llvmPackages.libclang`, or
        # `BINDGEN_EXTRA_CLANG_ARGS` at all. This is the actual point of
        # giving each service its own package instead of one `commonArgs`-wide
        # build: touching `svc-assets` no longer needs to build (or even have
        # installed) the GStreamer stack `svc-transcode`/`web-server` require,
        # and its own `cargoArtifacts` (`svcLightCargoArtifacts`, not
        # `gstreamerCargoArtifacts`) never rebuilds just because lib-gstreamer's
        # deps changed. Plain `buildPackage` with no `postFixup` -- unlike
        # `web-server`/`svc-transcode` there's no plugin registry to point
        # at and nothing needs `autoPatchelfHook`. Each still narrows
        # `cargoExtraArgs` down to just itself for the real build (unlike
        # `svcLightArgs`'s shared `-p svc-assets -p svc-download` for
        # `buildDepsOnly` above), so `$out/bin` holds exactly one binary.
        svc-assets = craneLib.buildPackage (
          svcLightIndividualCrateArgs
          // {
            pname = "svc-assets";
            cargoExtraArgs = "-p svc-assets";
            src = fileSetForCrate ./crates/services/svc-assets;
          }
        );

        svc-download = craneLib.buildPackage (
          svcLightIndividualCrateArgs
          // {
            pname = "svc-download";
            cargoExtraArgs = "-p svc-download";
            src = fileSetForCrate ./crates/services/svc-download;
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
        # web-server (its gstreamerArgs pkg-config-link against `gstPackages`,
        # which don't cross-build for free) so this image targets whatever
        # `system` it's built on, not a fixed architecture.
        web-server-image = pkgs.dockerTools.buildLayeredImage {
          name = "web-server";
          tag = "latest";
          created = "now";

          # Just the closure `web-server` actually needs at runtime:
          # itself (already rpath-wrapped against the GStreamer libs
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

        # Same GStreamer-rpath story as `web-server-image` -- `svc-transcode`
        # is already wrapped with `GST_PLUGIN_SYSTEM_PATH_1_0` by `nix build`,
        # so the image just needs the binary itself plus a CA bundle (its
        # gRPC server has no outbound HTTPS calls of its own today, but
        # costs nothing to include for whenever it does).
        svc-transcode-image = pkgs.dockerTools.buildLayeredImage {
          name = "svc-transcode";
          tag = "latest";
          created = "now";
          contents = [pkgs.cacert svc-transcode];
          config = {
            Cmd = ["${svc-transcode}/bin/svc-transcode"];
            Env = ["SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"];
            # Matches `SVC_TRANSCODE_ADDR`'s default in
            # crates/services/GRPC_MIGRATION.md.
            ExposedPorts = {"50051/tcp" = {};};
          };
        };

        # No GStreamer, no `autoPatchelfHook`/RPATH story to repeat here --
        # `svc-assets`/`svc-download` are plain rustls/glibc binaries, so
        # each image is just the binary plus a CA bundle for its own
        # outbound HTTPS (Cloudflare's API for `svc-assets`, the remote
        # index/ticket endpoints `lib-download` polls for `svc-download`).
        svc-assets-image = pkgs.dockerTools.buildLayeredImage {
          name = "svc-assets";
          tag = "latest";
          created = "now";
          contents = [pkgs.cacert svc-assets];
          config = {
            Cmd = ["${svc-assets}/bin/svc-assets"];
            Env = ["SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"];
            ExposedPorts = {"50052/tcp" = {};};
          };
        };

        svc-download-image = pkgs.dockerTools.buildLayeredImage {
          name = "svc-download";
          tag = "latest";
          created = "now";
          contents = [pkgs.cacert svc-download];
          config = {
            Cmd = ["${svc-download}/bin/svc-download"];
            Env = ["SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"];
            ExposedPorts = {"50053/tcp" = {};};
          };
        };
      in {
        packages =
          {
            inherit web-server web-frontend svc-transcode svc-assets svc-download;
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
            # Three separate caches now, matching the three
            # `*CargoArtifacts` used above: `cargo-deps-svc-light`
            # (`svcLightCargoArtifacts`, scoped to `-p svc-assets -p
            # svc-download`) backs those two -- no `gstPackages`/libclang
            # at all, so it's both cheaper to build and unaffected by
            # lib-gstreamer's deps changing. `cargo-deps-gstreamer` still covers
            # the whole native, GStreamer-linking side (`web-server` +
            # `svc-transcode`, plus everything `cargo-deps-svc-light`
            # already has -- `gstreamerArgs` sets no `cargoExtraArgs` scope at
            # all, so it's a strict superset of every other native scope).
            # `cargo-deps-frontend` is wasm32-only, as before.
            cargo-deps-svc-light = svcLightCargoArtifacts;
            cargo-deps-gstreamer = gstreamerCargoArtifacts;
            cargo-deps-frontend = frontendCargoArtifacts;
          }
          // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            inherit web-server-image svc-transcode-image svc-assets-image svc-download-image;
          };

        apps = {
          web-server = flake-utils.lib.mkApp {
            drv = web-server;
          };
          web-frontend = flake-utils.lib.mkApp {
            drv = web-frontend;
          };
          svc-transcode = flake-utils.lib.mkApp {
            drv = svc-transcode;
          };
          svc-assets = flake-utils.lib.mkApp {
            drv = svc-assets;
          };
          svc-download = flake-utils.lib.mkApp {
            drv = svc-download;
          };
        };

        devShells.default = craneLib.devShell {
          inputsFrom = [web-server web-frontend];

          LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
          BINDGEN_EXTRA_CLANG_ARGS = "-isystem ${pkgs.glibc.dev}/include";

          # `gstPackages` are a build input (via `gstreamerArgs`/`inputsFrom`
          # above) so `cargo build`/`check` links against them fine, but that
          # alone doesn't get `libgstreamer-1.0.so` et al onto the runtime
          # linker's search path — `nix build`'s wrapping would patch an
          # rpath in, but a plain `cargo test`/`cargo run` inside this
          # devShell doesn't go through that, and fails at process start
          # with "error while loading shared libraries: libgstreamer-1.0.so.0".
          LD_LIBRARY_PATH = lib.makeLibraryPath gstPackages;

          # GStreamer's element registry is populated by scanning plugin
          # .so's under each package's `lib/gstreamer-1.0/` at runtime, not
          # by anything on `LD_LIBRARY_PATH` — without this, pipeline
          # construction fails with "no element ... found" for everything
          # outside GStreamer's small always-linked core.
          GST_PLUGIN_SYSTEM_PATH_1_0 = lib.concatMapStringsSep ":" (p: "${p}/lib/gstreamer-1.0") gstPackages;

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
            # `protoc`, for lib-proto's build.rs — also in
            # commonArgs.nativeBuildInputs for `nix build`, but
            # `craneLib.devShell`'s `inputsFrom` only pulls in
            # web-server/web-frontend's own args, neither of which is
            # `commonArgs` itself, so it's listed again here explicitly.
            protobuf
          ];
        };
      }
    );
}