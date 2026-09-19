{
  # `pydevrpi` is a pull-only Cachix binary cache (see
  # https://app.cachix.org/cache/pydevrpi#pull) -- substitutes prebuilt
  # store paths (this project's own `cargo-deps-*`/aarch64-cross pushes,
  # or anything else already built under this cache's name) instead of
  # building them locally. `extra-*` so this adds to, rather than
  # replaces, Nix's own default `cache.nixos.org` substituter/key.
  # `nixConfig` is advisory: a first `nix build`/`flake check` against
  # this flake prompts to accept it (or needs
  # `--accept-flake-config`/`nix.settings.accept-flake-config` in
  # non-interactive contexts) before it actually takes effect.
  nixConfig = {
    extra-substituters = [ "https://pydevrpi.cachix.org" ];
    extra-trusted-public-keys = [ "pydevrpi.cachix.org-1:aAmJWUc+MjL0i2RcZO+mwW3EM5fV5XRLWGYjtcuKjj0=" ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self
    , nixpkgs
    , fenix
    , crane
    , flake-utils
    , ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
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

          buildInputs = [ ];

          nativeBuildInputs = [
            pkgs.pkg-config
            # Each svc-*'s own build.rs shells out to `protoc` to compile
            # its proto/*.proto (and, transitively, web-server needs it too
            # — see its Cargo.toml's comment on why it depends on the
            # svc-* crates directly) — in commonArgs rather than just
            # gstreamerArgs/web-server's own args so
            # `cargoArtifacts`/`buildDepsOnly` (which builds every
            # workspace member's deps, the svc-* crates included) has it
            # too.
            pkgs.protobuf
          ];
        };

        # lib-gstreamer drives a GStreamer pipeline (demux/parse/mux via
        # `gstreamer`/`gstreamer-app`'s Rust bindings) -- previously bound
        # ffmpeg-next directly, hence `gstreamerArgs`/`gstreamerCargoArtifacts`
        # etc. below having once been `ffmpeg*`-named (see git history if
        # that naming still turns up anywhere unexpected).
        #
        # `pipeline.rs` only ever constructs a small, fixed set of elements
        # (see its module doc's ASCII pipeline diagram and `make(...)`
        # call sites): `parsebin`/`decodebin`/`videoconvert`/`appsink`/
        # `appsrc`/typefind from `-base`; `qtdemux`/`matroskademux`/
        # `aacparse`/`splitmuxsink` from `-good`; `mpegtsmux`/`h264parse`/
        # `h265parse` from `-bad`, plus `openh264`/`libde265` there for
        # `decodebin`'s actual H.264/H.265 software decode (needed by the
        # poster/contact-sheet branch -- see `build_poster_branch` --
        # which `generate_poster`/`run_poster_only` reach unconditionally,
        # `GENERATE_POSTERS` only gating the *other* call site in `run`).
        # nixpkgs' own `gst-plugins-{base,good,bad}` build *every* plugin
        # each one ships (their own `meson.options`/`meson.build` list the
        # menu -- alsa/cdparanoia/pango/opus/vorbis/theora/GL/X11/Wayland
        # for `-base`; gtk3/qt5/qt6/jack/pulseaudio/v4l2/cairo/soup/taglib/
        # a dozen audio codecs for `-good`; the bulk of `-bad`'s ~150
        # options -- nvcodec/vulkan/d3d11/decklink/aja/webrtc/bluez/lv2/
        # ladspa/opencv/...), because nixpkgs' generic meson setup hook
        # passes `-Dauto_features=enabled` by default, which promotes
        # every 'auto'-valued feature option to a hard "enabled, fail the
        # build if the dep is missing" -- so nixpkgs' own `default.nix`
        # for each has to list every optional library as a real
        # (unconditional, for anything with no dedicated `*Support ?`
        # toggle) `buildInputs` entry just to keep that promise. None of
        # that is reachable from this crate's fixed element set, and it's
        # real weight: minutes of extra from-source build time natively,
        # and (the sharper edge, since this project cross-compiles to
        # aarch64 below) a much larger set of C libraries that has to
        # cross-build cleanly at all.
        #
        # `mkMinimalGst` flips that back: `-Dauto_features=disabled`
        # makes every *other* feature quietly skip (not fail) when its
        # dep is absent, then re-enables (`-D<plugin>=enabled`, which
        # keeps the "fail if the dep is missing" guarantee for just this
        # short list) only the plugins above -- all four of `-base`'s and
        # `-good`'s are in their own `meson.options`' "no external deps"
        # sections, so once `auto_features` no longer drags in
        # cairo/gtk3/pango/etc. to satisfy *other* plugins, those two
        # shrink to `orc` alone. `-bad`'s `openh264`/`libde265` do need
        # their libraries, so those stay; `enableGplPlugins = false`/
        # `bluezSupport = false`/`ldacbtSupport = false`/
        # `webrtcAudioProcessingSupport = false` shed the constructor-
        # level toggles nixpkgs already exposes for its other biggest
        # unconditional-buildInputs offenders (faad2/libmpeg2/mjpegtools/
        # x265, bluez, ldacbt, webrtc-audio-processing) before the
        # `buildInputs` replacement below drops the rest (json-glib/lcms2/
        # libass/openjpeg/curl/gsm/libaom/libdvdnav/openal/openexr/pango/
        # fluidsynth/gnutls/svt-av1/... -- see `-bad`'s own `default.nix`
        # for the full unconditional list this replaces). Threading `base`
        # in as each later stage's own `gst-plugins-base` override arg
        # (rather than just as a `buildInputs` entry) matters for `-bad`
        # specifically: its `mesonFlags`/`nativeBuildInputs` read
        # `gst-plugins-base.{waylandEnabled,glEnabled}` to decide whether
        # to probe for Wayland/libva/GL at all, and those passthru fields
        # need to come from *our* trimmed `-base` (X11/Wayland/GL all off)
        # to actually be false, not from nixpkgs' stock one.
        mkMinimalGst = p:
          let
            base = (p.gst_all_1.gst-plugins-base.override {
              enableX11 = false;
              enableWayland = false;
              enableAlsa = false;
              enableCdparanoia = false;
              withIntrospection = false;
              enableDocumentation = false;
            }).overrideAttrs (old: {
              mesonFlags =
                old.mesonFlags
                ++ [
                  "-Dauto_features=disabled"
                  # `auto_features=disabled` only pulls an *'auto'*-valued
                  # feature back to disabled -- `-base`'s own `mesonFlags`
                  # (above, in `old`) force `vorbis` to a hardcoded
                  # `enabled` unconditionally (no override arg gates it),
                  # so it has to be overridden explicitly here too or
                  # meson still requires `libvorbis` (dropped from
                  # `buildInputs` below) and fails the configure step.
                  "-Dvorbis=disabled"
                  "-Dplayback=enabled" # parsebin, decodebin
                  "-Dapp=enabled" # appsink, appsrc
                  "-Dvideoconvertscale=enabled" # videoconvert
                  "-Dtypefind=enabled" # backs parsebin/decodebin/qtdemux's type sniffing
                  "-Dorc=enabled"
                ];
              buildInputs = [ p.orc ];
            });

            good = (p.gst_all_1.gst-plugins-good.override {
              gst-plugins-base = base;
              gtkSupport = false;
              qt5Support = false;
              qt6Support = false;
              raspiCameraSupport = false;
              enableJack = false;
              enableX11 = false;
              enableWayland = false;
              enableDocumentation = false;
            }).overrideAttrs (old: {
              mesonFlags =
                old.mesonFlags
                ++ [
                  "-Dauto_features=disabled"
                  # `-good`'s own `mesonFlags` hardcode `dv1394`/`oss`/
                  # `oss4`/`pulse`/`v4l2`/`v4l2-gudev` to
                  # `stdenv.hostPlatform.isLinux` -- true unconditionally
                  # here, no override arg gates it -- rather than leaving
                  # them at their `meson.options` 'auto' default, so
                  # `auto_features=disabled` never touches them; each needs
                  # overriding back to `disabled` explicitly instead (found
                  # by trying: v4l2 built fine off the host's own kernel
                  # headers with no pkg-config dep at all, then failed
                  # configure for real over `v4l2-gudev`'s `gudev-1.0`
                  # pkg-config dependency, which isn't in `buildInputs`
                  # below; `dv1394` failed the same way over `libraw1394`).
                  "-Ddv1394=disabled"
                  "-Doss=disabled"
                  "-Doss4=disabled"
                  "-Dpulse=disabled"
                  "-Dv4l2=disabled"
                  "-Dv4l2-gudev=disabled"
                  "-Disomp4=enabled" # qtdemux
                  "-Dmatroska=enabled" # matroskademux
                  "-Daudioparsers=enabled" # aacparse
                  "-Dmultifile=enabled" # splitmuxsink
                  "-Dorc=enabled"
                ];
              buildInputs = [ base p.orc ];
            });

            bad = (p.gst_all_1.gst-plugins-bad.override {
              gst-plugins-base = base;
              enableGplPlugins = false;
              bluezSupport = false;
              ldacbtSupport = false;
              webrtcAudioProcessingSupport = false;
              # `ajaSupport` defaults to `lib.meta.availableOn ... libajantv2`,
              # which resolves true on this platform even though the AJA
              # NTV2 SDK itself isn't really fetchable in nixpkgs -- left at
              # its default, `-Daja=enabled` fails configure hunting for a
              # `libajantv2.pc` that doesn't exist. Same story as
              # `openh264Support` below, just the opposite direction.
              ajaSupport = false;
              openh264Support = true;
              enableDocumentation = false;
            }).overrideAttrs (old: {
              mesonFlags =
                old.mesonFlags
                ++ [
                  "-Dauto_features=disabled"
                  # Same story as `-base`'s `vorbis` above: `-bad`'s own
                  # `mesonFlags` force `openaptx` to a hardcoded `enabled`
                  # unconditionally, needing `libfreeaptx` (dropped from
                  # `buildInputs` below).
                  "-Dopenaptx=disabled"
                  "-Dmpegtsmux=enabled"
                  # `mpegtsmux`/`mpegtsdemux` are separate meson options
                  # despite both living in the historical "mpegtsmux"
                  # source tree -- `tsdemux` (from the latter) is what lets
                  # `decodebin` read a rendition's own `.ts` segments back,
                  # which the HLS-based poster-regen path (`hlsdemux` below
                  # feeding straight into `decodebin`, see pipeline.rs's
                  # `run_poster_only`/`build_poster_branch`, unchanged)
                  # needs downstream of the demuxed HLS stream.
                  "-Dmpegtsdemux=enabled" # tsdemux
                  "-Dvideoparsers=enabled" # h264parse, h265parse
                  "-Dopenh264=enabled" # openh264dec, decodebin's H.264 software decoder
                  "-Dlibde265=enabled" # libde265dec, decodebin's H.265 software decoder
                  # `hlsdemux`, so a poster/contact-sheet regen job can be
                  # pointed at a video's own published rendition playlist
                  # (`VideoSource::Url` to the `.m3u8`) instead of only its
                  # original, possibly-no-longer-reachable `source_url` --
                  # `decodebin` autoplugs it for `application/x-hls` the
                  # same way it already autoplugs `qtdemux`/`matroskademux`
                  # for other containers, so no pipeline.rs changes are
                  # needed for this to work once the plugin exists.
                  # `hls-crypto=openssl` is what lets it decrypt our own
                  # AES-128 segments (`encrypt.rs`) via the `#EXT-X-KEY`
                  # line `playlist.rs` writes -- picked over nettle/
                  # libgcrypt purely because `p.openssl` is already a
                  # dependency elsewhere in this flake, not for any
                  # feature reason.
                  "-Dhls=enabled"
                  "-Dhls-crypto=openssl"
                  "-Dorc=enabled"
                ];
              buildInputs = [ base p.orc p.openh264 p.libde265 p.openssl ];
            });
          in
          { inherit base good bad; };

        # `reqwesthttpsrc` (see `gstPackages`' comment below) hard-aborts
        # the whole process on a zero-length, non-final HTTP/2 DATA frame --
        # `create()` treats it as unreachable via `assert_ne!(chunk.len(),
        # 0)`, but Cloudflare's Workers-assets edge does send that shape for
        # large segment responses, and an `assert!` panicking inside a
        # `PushSrcImpl::create` call isn't a `Result` `gst_adaptive_demux`
        # can recover from -- it poisons `ReqwestHttpSrc::state`'s mutex,
        # and the next `set_location` on any other `reqwesthttpsrc`
        # instance (a normal, unrelated call) hits that poisoned lock from
        # across a `extern "C"` GObject vtable call that can't unwind,
        # aborting the process outright. The patch makes an empty `Some`
        # chunk just poll again instead -- only a `None` chunk is really
        # end-of-stream.
        patchedGstPluginsRs = p:
          (p.gst_all_1.gst-plugins-rs.override { plugins = [ "reqwest" ]; }).overrideAttrs (old: {
            patches =
              (old.patches or [ ])
              ++ [ ./nix/patches/gst-plugins-rs-reqwesthttpsrc-skip-empty-chunk.patch ];
          });

        gstMinimal = mkMinimalGst pkgs;

        gstPackages = with pkgs.gst_all_1; [
          gstreamer
          gstMinimal.base
          gstMinimal.good
          gstMinimal.bad
          # nixpkgs' `gst-plugins-rs` builds *every* Rust plugin by default
          # (webrtc, gtk4, whisper, csound, aws, ndi, ...), pulling in gtk4/
          # cairo/whisper.cpp/aws-lc-rs/csound as real build (and runtime
          # closure) deps -- pipeline.rs only ever asks for one element out
          # of that whole set, `reqwesthttpsrc` (the URL-source branch of
          # `video_source_element`), which is the `reqwest` plugin. Scoping
          # `plugins` down to just that trades the full build's
          # cache.nixos.org substitute for a from-source build, but it's a
          # much smaller one -- no gtk4/whisper/csound/aws in the closure at
          # all, and (since `plugins != [ "whisper" ]`) nixpkgs' own
          # `requiresBindgen` stays false too, so this doesn't drag cmake/
          # bindgen back in behind our backs either.
          (patchedGstPluginsRs pkgs)
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

        # Scoped with `-p` (like `svcLightArgs`/`frontendArgs`): without
        # it `buildDepsOnly` would also build `lib-ffmpeg`'s dependency
        # graph (ffmpeg-sys-next, which needs FFmpeg's headers), which
        # this GStreamer-only scope deliberately doesn't have. FFmpeg is
        # never pulled into the GStreamer build, or vice versa.
        gstreamerArgs =
          commonArgs
          // {
            buildInputs = (commonArgs.buildInputs or [ ]) ++ gstPackages;
            cargoExtraArgs = "--locked -p lib-gstreamer -p svc-transcode -p web-server";
          };

        # lib-ffmpeg drives libav* through `ffmpeg-next`/`ffmpeg-sys-next`,
        # which find FFmpeg via pkg-config (`pkgs.ffmpeg` provides both the
        # libs and `.pc` files) and generate their bindings with bindgen
        # (`bindgenHook` supplies libclang + its include paths). The default
        # `pkgs.ffmpeg` includes libx264, which `RealignKeyframes` uses.
        # No GStreamer input here -- the mirror image of `gstreamerArgs`.
        # `ffmpeg-headless` (no X11/SDL/GTK/GStreamer/bluez... -- same
        # reason `mkMinimalGst` exists: those don't cross-compile to
        # aarch64) plus libx264 for `RealignKeyframes`. Headless still has
        # VA-API, https (TLS) and the hls muxer.
        mkMinimalFfmpeg = p:
          (p.ffmpeg-headless.override {
            withHeadlessDeps = false;
            withVaapi = !p.stdenv.hostPlatform.isStatic;
            withX264 = true; # libx264 encoder (needs withGPL, which is the default)
            withNetwork = true;
            withGnutls = true; # HTTPS; drop it if you only use HLS over plain HTTP or local files
            withZlib = true; # gzip/deflate HTTP responses; tiny and commonly needed
            buildFfmpeg = true;
            buildFfprobe = true;
            buildFfplay = false;
            buildAvcodec = true;
            buildAvformat = true;
            buildAvfilter = true; # needed for -vf scale_vaapi, hwupload, etc.
            buildAvutil = true;
            buildSwresample = true;
            buildSwscale = true; # software scaling/pixel conversion for libx264
            buildAvdevice = false; # capture devices (v4l2, alsa); not needed

            # --- Build hygiene --------------------------------------------------
            withSafeBitstreamReader = true; # bounds checking; recommended with untrusted streams
            withHardcodedTables = true; # build-time only, no extra deps

            # No documentation
            withHtmlDoc = false;
            withManPages = false;
            withPodDoc = false;
            withTxtDoc = false;
          }).overrideAttrs (_: {
            # `make check` builds FFmpeg's own test programs, which fail to
            # compile under static musl (e.g. libavutil/tests/pixelutils.c).
            doCheck = false;
          });
        ffmpegPackages = [ (mkMinimalFfmpeg pkgs) ];

        ffmpegArgs =
          commonArgs
          // {
            pname = "next_file_browser-ffmpeg";
            buildInputs = (commonArgs.buildInputs or [ ]) ++ ffmpegPackages;
            nativeBuildInputs = commonArgs.nativeBuildInputs ++ [ pkgs.rustPlatform.bindgenHook ];
            # `svc-transcode`'s `ffmpeg` feature (default `gstreamer` off) is
            # what makes it link lib-ffmpeg instead of lib-gstreamer.
            cargoExtraArgs = "--locked -p lib-ffmpeg -p svc-transcode --no-default-features --features svc-transcode/ffmpeg";
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
              (commonArgs.buildInputs or [ ])
              ++ [
                pkgs.openssl
              ];

            nativeBuildInputs =
              (commonArgs.nativeBuildInputs or [ ])
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
        # transitively via `cargoArtifacts`. `web-server` joined this tier
        # once its own `lib-gstreamer` dependency edge went
        # `default-features = false`, and it started depending on
        # `lib-transcode-client` (which itself hardcodes that same
        # `default-features = false`) instead of `svc-transcode` itself
        # (see those crates' Cargo.toml comments) -- it no longer touches
        # GStreamer either, just the `Transcoder` trait/types, so it
        # belongs here rather than under `gstreamerArgs` below. The three
        # `lib-*-client` crates (lib-only, no binary of their own) don't
        # need their own `-p` entry -- `cargo build -p web-server` already
        # pulls each in transitively as a path dependency. Naming all three
        # `cargoExtraArgs` (rather than a separate scope each) builds
        # their heavily-overlapping shared deps (tonic/prost/tokio/reqwest/
        # axum) once instead of three times.
        svcLightArgs =
          commonArgs
          // {
            cargoExtraArgs = "-p svc-assets -p svc-download -p web-server";
          };

        gstreamerCargoArtifacts = craneLib.buildDepsOnly gstreamerArgs;
        ffmpegCargoArtifacts = craneLib.buildDepsOnly ffmpegArgs;
        frontendCargoArtifacts = craneLib.buildDepsOnly frontendArgs;
        svcLightCargoArtifacts = craneLib.buildDepsOnly svcLightArgs;

        svcLightIndividualCrateArgs =
          commonArgs
          // {
            cargoArtifacts = svcLightCargoArtifacts;
            inherit (craneLib.crateNameFromCargoToml { inherit src; }) version;
          };

        gstreamerIndividualCrateArgs =
          gstreamerArgs
          // {
            cargoArtifacts = gstreamerCargoArtifacts;
            inherit (craneLib.crateNameFromCargoToml { inherit src; }) version;
          };

        ffmpegIndividualCrateArgs =
          ffmpegArgs
          // {
            cargoArtifacts = ffmpegCargoArtifacts;
            inherit (craneLib.crateNameFromCargoToml { inherit src; }) version;
          };

        frontendIndividualCrateArgs =
          frontendArgs
          // {
            cargoArtifacts = frontendCargoArtifacts;
            inherit (craneLib.crateNameFromCargoToml { inherit src; }) version;
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
              # Same story: each lib-*-client's own build.rs (the proto
              # codegen now lives there, not in svc-transcode/svc-assets/
              # svc-download themselves -- see those crates' Cargo.toml
              # comments) shells out to `protoc` against its own
              # `proto/*.proto` at *compile* time (see
              # commonArgs.nativeBuildInputs's comment on that build.rs) --
              # `commonCargoSources` doesn't sweep up non-Rust files, so
              # without these every lib-*-client (and svc-*/web-server
              # transitively) fails to build with "protoc failed: ... No
              # such file or directory".
              ./crates/libs/lib-transcode-client/proto
              ./crates/libs/lib-assets-client/proto
              ./crates/libs/lib-download-client/proto
              # lib-transcode's `conformance` suite reads these small media
              # fixtures at *test* time (see `checks` below).
              ./crates/libs/lib-transcode/fixtures
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
              (craneLib.fileset.commonCargoSources crate)
            ];
          };

        # `web-server` used to link GStreamer directly (the in-process
        # `Transcoder`/`AssetStore` fallback) and needed the same RPATH/
        # `GST_PLUGIN_SYSTEM_PATH_1_0` wrapping `svc-transcode` still does
        # below. That fallback is gone -- `SVC_TRANSCODE_ADDR`/
        # `SVC_ASSETS_ADDR`/`SVC_DOWNLOAD_ADDR` are required now (fails
        # startup outright rather than silently running the heavy backend
        # in-process, see `main.rs`'s module doc), and web-server depends
        # on `lib-transcode-client` (not `svc-transcode` itself), which
        # hardcodes `lib-gstreamer`'s `default-features = false` (see
        # those crates' own Cargo.toml comments) -- so this is a plain
        # `svcLightIndividualCrateArgs` build now, same shape as
        # `svc-assets`/`svc-download` below: no `gstPackages`
        # `buildInputs`, no `autoPatchelfHook`/`postFixup` RPATH dance.
        web-server = craneLib.buildPackage (
          svcLightIndividualCrateArgs
          // {
            pname = "web-server";
            cargoExtraArgs = "-p web-server";
            src = fileSetForCrate ./crates/services/web-server;
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
            nativeBuildInputs = gstreamerIndividualCrateArgs.nativeBuildInputs ++ [ pkgs.autoPatchelfHook pkgs.makeWrapper ];

            postFixup = ''
              wrapProgram $out/bin/svc-transcode \
                --set GST_PLUGIN_SYSTEM_PATH_1_0 "${lib.concatMapStringsSep ":" (p: "${p.out}/lib/gstreamer-1.0") gstPackages}"
            '';
          }
        );

        # The same gRPC service built against FFmpeg instead of GStreamer
        # (`--no-default-features --features ffmpeg`): a separate binary and
        # image so a deployment ships exactly one media stack. libav* is
        # linked directly (no plugin registry to point at, unlike GStreamer),
        # so the cc wrapper's RPATH is enough -- no autoPatchelf/wrapProgram.
        svc-transcode-ffmpeg = craneLib.buildPackage (
          ffmpegIndividualCrateArgs
          // {
            pname = "svc-transcode-ffmpeg";
            cargoExtraArgs = "--locked -p svc-transcode --no-default-features --features ffmpeg";
            src = fileSetForCrate ./crates/services/svc-transcode;
            # crane names the installed binary after the crate.
            postInstall = ''
              mv $out/bin/svc-transcode $out/bin/svc-transcode-ffmpeg
            '';
          }
        );

        # Library packages, one per transcoding crate: `nix build
        # .#lib-transcode|lib-gstreamer|lib-ffmpeg` compiles just that crate
        # (against only its own native inputs) and installs its rlib.
        mkLibPackage =
          { name
          , args
          , artifacts
          ,
          }:
          craneLib.mkCargoDerivation (
            args
            // {
              pname = name;
              inherit (craneLib.crateNameFromCargoToml { inherit src; }) version;
              cargoArtifacts = artifacts;
              src = fileSetForCrate ./crates/libs/${name};
              cargoExtraArgs = "--locked -p ${name}";
              buildPhaseCargoCommand = "cargo build --release --locked -p ${name}";
              doInstallCargoArtifacts = false;
              installPhaseCommand = ''
                mkdir -p $out/lib
                cp target/release/lib${lib.replaceStrings ["-"] ["_"] name}.rlib $out/lib/
              '';
            }
          );

        # lib-transcode has no native deps at all, so it builds against the
        # plain (input-free) common args -- the point of the crate.
        libTranscodeArgs =
          commonArgs
          // {
            pname = "next_file_browser-lib-transcode";
            cargoExtraArgs = "--locked -p lib-transcode";
          };
        lib-transcode = mkLibPackage {
          name = "lib-transcode";
          args = libTranscodeArgs;
          artifacts = craneLib.buildDepsOnly libTranscodeArgs;
        };
        lib-gstreamer = mkLibPackage {
          name = "lib-gstreamer";
          args = gstreamerArgs;
          artifacts = gstreamerCargoArtifacts;
        };
        lib-ffmpeg = mkLibPackage {
          name = "lib-ffmpeg";
          args = ffmpegArgs;
          artifacts = ffmpegCargoArtifacts;
        };

        # Runs the shared `lib-transcode` conformance suite (plus each
        # backend's own tests) in the sandbox, against both backends. The
        # suite shells out to `ffprobe`, and lib-gstreamer's older
        # fixture-generating tests to `ffmpeg`, hence `pkgs.ffmpeg` as a
        # test-only tool; GStreamer additionally needs its plugin registry
        # pointed at (see the `svc-transcode` wrapper / devShell).
        testSrc = fileSetForCrate ./crates/libs/lib-transcode;
        lib-gstreamer-tests = craneLib.cargoTest (
          gstreamerArgs
          // {
            src = testSrc;
            cargoArtifacts = gstreamerCargoArtifacts;
            cargoExtraArgs = "--locked -p lib-transcode -p lib-gstreamer";
            # `commonArgs` sets doCheck = false (web-server/lib-db need Postgres);
            # these are pure media tests, so turn it back on.
            doCheck = true;
            nativeCheckInputs = [ pkgs.ffmpeg ];
            GST_PLUGIN_SYSTEM_PATH_1_0 = lib.concatMapStringsSep ":" (p: "${p}/lib/gstreamer-1.0") gstPackages;
            # No rpath patching yet at cargo-test time (see the devShell).
            LD_LIBRARY_PATH = lib.makeLibraryPath gstPackages;
          }
        );
        lib-ffmpeg-tests = craneLib.cargoTest (
          ffmpegArgs
          // {
            src = testSrc;
            cargoArtifacts = ffmpegCargoArtifacts;
            cargoExtraArgs = "--locked -p lib-transcode -p lib-ffmpeg";
            LD_LIBRARY_PATH = lib.makeLibraryPath ffmpegPackages;
            # `commonArgs` sets doCheck = false (web-server/lib-db need Postgres);
            # these are pure media tests, so turn it back on.
            doCheck = true;
            nativeCheckInputs = [ pkgs.ffmpeg ];
          }
        );

        # `svc-assets`/`svc-download` link none of `lib-gstreamer`'s GStreamer
        # bindings (see crates/services/GRPC_MIGRATION.md's per-service
        # dependency table: `svc-assets` wraps `lib-storage`+`lib-cloudflare`
        # +`lib-db`, `svc-download` wraps `lib-download` -- reqwest/sqlx over
        # rustls, no native libs beyond glibc) -- built from
        # `svcLightIndividualCrateArgs` rather than `gstreamerIndividualCrateArgs`,
        # so neither one pulls in `gstPackages` at all. This is the actual
        # point of giving each service its own package instead of one
        # `commonArgs`-wide
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

        # ---------------------------------------------------------------
        # arm64 cross-compilation, for the three svc-* gRPC services only
        # (not web-server/web-frontend -- web-frontend is wasm32, already
        # arch-independent, and web-server would need this exact same
        # GStreamer-cross story as svc-transcode below, just not done yet).
        # Only defined from an x86_64-linux host: on a native aarch64-linux
        # builder this would be a pointless cross-of-same-arch, and
        # dockerTools/cross toolchains aren't a Darwin thing at all.
        #
        # This deliberately mirrors the svcLight/gstreamer split above --
        # the whole point of that split was so touching svc-assets doesn't
        # rebuild svc-transcode's (GStreamer) deps; cross-compiling adds a
        # *second* axis (target arch) to cache along, not a reason to
        # collapse the first one. `armSvcLightCargoArtifacts` never touches
        # GStreamer at all, cross or not.
        # ---------------------------------------------------------------
        crossEnabled = system == "x86_64-linux";

        # Static musl: every arm64 binary is fully self-contained (no glibc,
        # no RPATH/`patchelf`/`autoPatchelfHook` story -- the reason the old
        # gnu variant needed hand-set RPATHs), so images are just binary +
        # CA bundle. `armPkgsCross` is the `pkgsStatic` set (static `.a`
        # libs, used for linking); `armPkgsMusl` is the plain musl cross set
        # (only for `dockerTools`, so the image's Architecture is "arm64").
        armPkgsMusl = pkgs.pkgsCross.aarch64-multiplatform-musl;
        armPkgsCross = armPkgsMusl.pkgsStatic;
        armTargetTriple = "aarch64-unknown-linux-musl";
        armTargetEnv = lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] armTargetTriple);

        armRustToolchain = fenix.packages.${system}.combine [
          fenix.packages.${system}.stable.toolchain
          fenix.packages.${system}.stable.rust-src
          fenix.packages.${system}.targets.${armTargetTriple}.stable.rust-std
        ];

        armCraneLib = (crane.mkLib pkgs).overrideToolchain armRustToolchain;

        # The cross gcc that *runs* on the build host (x86_64) but
        # produces aarch64 code -- `armPkgsCross.stdenv.cc` itself (no
        # `.buildPackages`) is already the right one here, since
        # `pkgsCross.<target>.stdenv.cc` *is* a build-host-hosted
        # cross-compiler by construction (that's what makes it a "cross"
        # stdenv rather than a QEMU-emulated native one).
        armCC = "${armPkgsCross.stdenv.cc}/bin/${armPkgsCross.stdenv.cc.targetPrefix}cc";

        armCommonArgs =
          commonArgs
          // {
            CARGO_BUILD_TARGET = armTargetTriple;
            "CARGO_TARGET_${armTargetEnv}_LINKER" = armCC;
            TARGET_CC = armCC;
            HOST_CC = "${pkgs.stdenv.cc}/bin/cc";
            # Without this, `system-deps`/pkg-config-linked `-sys` crates
            # (gstreamer-sys et al, below) refuse to run pkg-config at all
            # once `CARGO_BUILD_TARGET` != the build host's own target,
            # erroring "pkg-config has not been configured to support
            # cross-compilation" instead of resolving anything.
            PKG_CONFIG_ALLOW_CROSS = "1";

            nativeBuildInputs =
              (commonArgs.nativeBuildInputs or [ ])
              ++ [
                # The pkg-config *binary* still has to run on the build
                # host (x86_64) -- but wrapped (via nixpkgs' splicing) to
                # search the aarch64 sysroot's .pc files instead of the
                # host's own. Plain `pkgs.pkg-config` (already in
                # `commonArgs`, kept for `protobuf`'s sake) would resolve
                # x86_64 .pc files and either link the wrong ELF class or
                # fail outright.
                armPkgsCross.buildPackages.pkg-config
              ];
          };

        # `armPkgsCross.ffmpeg` is the static aarch64 libav* (linked via the cross pkg-config wrapper
        # from `armCommonArgs`); `bindgenHook` from the cross package set
        # points bindgen's libclang at the aarch64 sysroot headers.
        armFfmpegPackages = [ (mkMinimalFfmpeg armPkgsCross) ];
        armFfmpegArgs =
          armCommonArgs
          // {
            pname = "next_file_browser-ffmpeg";
            # Link libav*/x264 statically (musl, no dynamic loader at runtime).
            PKG_CONFIG_ALL_STATIC = "1";
            buildInputs = (armCommonArgs.buildInputs or [ ]) ++ armFfmpegPackages;
            nativeBuildInputs = armCommonArgs.nativeBuildInputs ++ [ armPkgsCross.rustPlatform.bindgenHook ];
            cargoExtraArgs = "--locked -p lib-ffmpeg -p svc-transcode --no-default-features --features svc-transcode/ffmpeg";
          };

        # Matches `svcLightArgs` above: `-p svc-assets -p svc-download -p
        # web-server` built (and dep-cached) together, GStreamer nowhere
        # in reach.
        armSvcLightArgs =
          armCommonArgs
          // {
            cargoExtraArgs = "-p svc-assets -p svc-download -p web-server";
          };

        armSvcLightCargoArtifacts = armCraneLib.buildDepsOnly armSvcLightArgs;
        armFfmpegCargoArtifacts = armCraneLib.buildDepsOnly armFfmpegArgs;

        armSvcLightIndividualCrateArgs =
          armCommonArgs
          // {
            cargoArtifacts = armSvcLightCargoArtifacts;
            inherit (armCraneLib.crateNameFromCargoToml { inherit src; }) version;
          };

        # FFmpeg-backed svc-transcode for arm64: libav* is linked statically
        # into a musl binary, so no RPATH fixup -- just rename the binary.
        svc-transcode-ffmpeg-aarch64 = armCraneLib.buildPackage (
          armFfmpegArgs
          // {
            cargoArtifacts = armFfmpegCargoArtifacts;
            inherit (armCraneLib.crateNameFromCargoToml { inherit src; }) version;
            pname = "svc-transcode-ffmpeg";
            cargoExtraArgs = "--locked -p svc-transcode --no-default-features --features ffmpeg";
            src = fileSetForCrate ./crates/services/svc-transcode;
            postFixup = ''
              mv $out/bin/svc-transcode $out/bin/svc-transcode-ffmpeg
            '';
          }
        );

        # `web-server` no longer links GStreamer at all (see the native
        # `web-server` package's comment) -- plain `armSvcLightIndividualCrateArgs`,
        # same shape as `svc-assets-aarch64`/`svc-download-aarch64` below.
        web-server-aarch64 = armCraneLib.buildPackage (
          armSvcLightIndividualCrateArgs
          // {
            pname = "web-server";
            cargoExtraArgs = "-p web-server";
            src = fileSetForCrate ./crates/services/web-server;
          }
        );

        svc-assets-aarch64 = armCraneLib.buildPackage (
          armSvcLightIndividualCrateArgs
          // {
            pname = "svc-assets";
            cargoExtraArgs = "-p svc-assets";
            src = fileSetForCrate ./crates/services/svc-assets;
          }
        );

        svc-download-aarch64 = armCraneLib.buildPackage (
          armSvcLightIndividualCrateArgs
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
        # build on Darwin. Targets whatever `system` it's built on, not a
        # fixed architecture -- see `web-server-image-aarch64` below for
        # the arm64 cross-compiled counterpart.
        web-server-image = pkgs.dockerTools.buildLayeredImage {
          name = "web-server";
          tag = "latest";
          created = "now";

          # Just the closure `web-server` actually needs at runtime: no
          # GStreamer libs anymore (see the `web-server` package comment
          # above), just itself plus a CA bundle -- rustls-over-HTTPS to
          # each `svc-*` instance is unlikely to ever need this in
          # practice (plain `http://` inside a private network is the
          # documented example, see `GRPC_MIGRATION.md`), but it's cheap
          # insurance if one's ever fronted by TLS.
          contents = [ pkgs.cacert web-server ];

          config = {
            Cmd = [ "${web-server}/bin/web-server" ];
            # Writable at runtime (the container's overlay, not the R/O
            # nix store) -- `LOCAL_ASSETS_DIR` (default "data/assets",
            # relative to this) is `create_dir_all`'d on startup. Mount a
            # volume here to persist it across container recreates.
            WorkingDir = "/data";
            Env = [ "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" ];
            ExposedPorts = { "3001/tcp" = { }; };
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
          contents = [ pkgs.cacert svc-transcode ];
          config = {
            Cmd = [ "${svc-transcode}/bin/svc-transcode" ];
            Env = [
              "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              # Keeps splitmuxsink's segment writes and the
              # poster/contact-sheet decode branch off disk (see
              # service.rs::scratch_dir, .env.example) -- Docker/OCI's
              # default /dev/shm is only 64MB though, so whatever runs
              # this image still has to size it up itself (e.g. `docker
              # run --shm-size 2g`, or the equivalent tmpfs volume size
              # on reze-pi's compose/k8s config) or GStreamer will hit
              # ENOSPC partway through a job.
              "SVC_TRANSCODE_SCRATCH_DIR=/dev/shm"
            ];
            # Matches `SVC_TRANSCODE_ADDR`'s default in
            # crates/services/GRPC_MIGRATION.md.
            ExposedPorts = { "50051/tcp" = { }; };
          };
        };

        # FFmpeg-backed counterpart of `svc-transcode-image`: same service,
        # same port and scratch-dir convention, no GStreamer in the closure.
        svc-transcode-ffmpeg-image = pkgs.dockerTools.buildLayeredImage {
          name = "svc-transcode-ffmpeg";
          tag = "latest";
          created = "now";
          contents = [ pkgs.cacert svc-transcode-ffmpeg ];
          config = {
            Cmd = [ "${svc-transcode-ffmpeg}/bin/svc-transcode-ffmpeg" ];
            Env = [
              "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              "SVC_TRANSCODE_SCRATCH_DIR=/dev/shm"
            ];
            ExposedPorts = { "50051/tcp" = { }; };
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
          contents = [ pkgs.cacert svc-assets ];
          config = {
            Cmd = [ "${svc-assets}/bin/svc-assets" ];
            Env = [ "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" ];
            ExposedPorts = { "50052/tcp" = { }; };
          };
        };

        svc-download-image = pkgs.dockerTools.buildLayeredImage {
          name = "svc-download";
          tag = "latest";
          created = "now";
          contents = [ pkgs.cacert svc-download ];
          config = {
            Cmd = [ "${svc-download}/bin/svc-download" ];
            Env = [ "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" ];
            ExposedPorts = { "50053/tcp" = { }; };
          };
        };

        # arm64 counterparts of the three images above, built from the
        # `*-aarch64` derivations. `armPkgsMusl.dockerTools` (not
        # `pkgs.dockerTools`) so the image's own Architecture metadata comes
        # out "arm64" -- layer assembly itself (tar/gzip) still just runs on
        # the build host, no emulation needed either way. Tagged
        # "linux-arm64" rather than reusing "latest" so both architectures'
        # images can be pushed to the same repository and combined into one
        # multi-arch manifest afterwards (e.g. `docker manifest create` /
        # `docker buildx imagetools create`) without one overwriting the
        # other.
        svc-transcode-ffmpeg-image-aarch64 = armPkgsMusl.dockerTools.buildLayeredImage {
          name = "svc-transcode-ffmpeg";
          tag = "linux-arm64";
          created = "now";
          contents = [ armPkgsMusl.cacert svc-transcode-ffmpeg-aarch64 ];
          config = {
            Cmd = [ "${svc-transcode-ffmpeg-aarch64}/bin/svc-transcode-ffmpeg" ];
            Env = [
              "SSL_CERT_FILE=${armPkgsMusl.cacert}/etc/ssl/certs/ca-bundle.crt"
              "SVC_TRANSCODE_SCRATCH_DIR=/dev/shm"
            ];
            ExposedPorts = { "50051/tcp" = { }; };
          };
        };

        svc-assets-image-aarch64 = armPkgsMusl.dockerTools.buildLayeredImage {
          name = "svc-assets";
          tag = "linux-arm64";
          created = "now";
          contents = [ armPkgsMusl.cacert svc-assets-aarch64 ];
          config = {
            Cmd = [ "${svc-assets-aarch64}/bin/svc-assets" ];
            Env = [ "SSL_CERT_FILE=${armPkgsMusl.cacert}/etc/ssl/certs/ca-bundle.crt" ];
            ExposedPorts = { "50052/tcp" = { }; };
          };
        };

        svc-download-image-aarch64 = armPkgsMusl.dockerTools.buildLayeredImage {
          name = "svc-download";
          tag = "linux-arm64";
          created = "now";
          contents = [ armPkgsMusl.cacert svc-download-aarch64 ];
          config = {
            Cmd = [ "${svc-download-aarch64}/bin/svc-download" ];
            Env = [ "SSL_CERT_FILE=${armPkgsMusl.cacert}/etc/ssl/certs/ca-bundle.crt" ];
            ExposedPorts = { "50053/tcp" = { }; };
          };
        };

        # Same story as `web-server-image` above, cross-compiled -- the
        # asset dir (`LOCAL_ASSETS_DIR`, default "data/assets") is
        # `create_dir_all`'d on startup same as the native image, so
        # `WorkingDir = "/data"` is carried over here too.
        web-server-image-aarch64 = armPkgsMusl.dockerTools.buildLayeredImage {
          name = "web-server";
          tag = "linux-arm64";
          created = "now";
          contents = [ armPkgsMusl.cacert web-server-aarch64 ];
          config = {
            Cmd = [ "${web-server-aarch64}/bin/web-server" ];
            WorkingDir = "/data";
            Env = [ "SSL_CERT_FILE=${armPkgsMusl.cacert}/etc/ssl/certs/ca-bundle.crt" ];
            ExposedPorts = { "3001/tcp" = { }; };
          };
        };
      in
      {
        packages =
          {
            inherit web-server web-frontend svc-transcode svc-transcode-ffmpeg svc-assets svc-download;
            inherit lib-transcode lib-gstreamer lib-ffmpeg;
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
            # svc-download`) backs those two -- no `gstPackages` at all, so
            # it's both cheaper to build and unaffected by
            # lib-gstreamer's deps changing. `cargo-deps-gstreamer` still covers
            # the whole native, GStreamer-linking side (`web-server` +
            # `svc-transcode`, plus everything `cargo-deps-svc-light`
            # already has -- `gstreamerArgs` sets no `cargoExtraArgs` scope at
            # all, so it's a strict superset of every other native scope).
            # `cargo-deps-frontend` is wasm32-only, as before.
            cargo-deps-svc-light = svcLightCargoArtifacts;
            cargo-deps-gstreamer = gstreamerCargoArtifacts;
            cargo-deps-ffmpeg = ffmpegCargoArtifacts;
            cargo-deps-frontend = frontendCargoArtifacts;
          }
          // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
            inherit web-server-image svc-transcode-image svc-transcode-ffmpeg-image svc-assets-image svc-download-image;
          }
          // lib.optionalAttrs crossEnabled {
            inherit web-server-aarch64 svc-transcode-ffmpeg-aarch64 svc-assets-aarch64 svc-download-aarch64;
            inherit web-server-image-aarch64 svc-transcode-ffmpeg-image-aarch64 svc-assets-image-aarch64 svc-download-image-aarch64;

            # Warm-the-Cachix-cache story as above, for the static musl
            # arm64 target (no GStreamer variant: it dlopens plugins, which
            # a static musl binary can't do).
            cargo-deps-svc-light-aarch64 = armSvcLightCargoArtifacts;
            cargo-deps-ffmpeg-aarch64 = armFfmpegCargoArtifacts;
          };

        checks = {
          # lib-gstreamer-tests / lib-ffmpeg-tests are defined above but disabled here.
          inherit lib-transcode lib-gstreamer lib-ffmpeg;
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
          svc-transcode-ffmpeg = flake-utils.lib.mkApp {
            drv = svc-transcode-ffmpeg;
          };
          svc-assets = flake-utils.lib.mkApp {
            drv = svc-assets;
          };
          svc-download = flake-utils.lib.mkApp {
            drv = svc-download;
          };
        };

        devShells.default = craneLib.devShell {
          # `svc-transcode`, not `web-server` -- `web-server` dropped its
          # `gstPackages` buildInputs entirely once its `lib-gstreamer`
          # dependency edge went `default-features = false` and it
          # started depending on `lib-transcode-client` (also
          # `default-features = false`) instead of `svc-transcode` itself
          # (see the `web-server` package's own comment), so
          # `svc-transcode` is the one crate left whose own args still
          # pull GStreamer's headers/.pc files in for `cargo build`/
          # `check -p svc-transcode` inside this shell to link against.
          inputsFrom = [ svc-transcode svc-transcode-ffmpeg web-frontend ];

          # `gstPackages` are a build input (via `gstreamerArgs`/`inputsFrom`
          # above) so `cargo build`/`check` links against them fine, but that
          # alone doesn't get `libgstreamer-1.0.so` et al onto the runtime
          # linker's search path — `nix build`'s wrapping would patch an
          # rpath in, but a plain `cargo test`/`cargo run` inside this
          # devShell doesn't go through that, and fails at process start
          # with "error while loading shared libraries: libgstreamer-1.0.so.0".
          LD_LIBRARY_PATH = lib.makeLibraryPath (gstPackages ++ ffmpegPackages);

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
            sqlx-cli
            dioxus-cli
            # wasm-bindgen-cli intentionally omitted — see the comment by
            # frontendArgs.nativeBuildInputs above.
            binaryen
            tailwindcss
            # `protoc`, for each svc-*'s build.rs — also in
            # commonArgs.nativeBuildInputs for `nix build`, but
            # `craneLib.devShell`'s `inputsFrom` only pulls in
            # web-server/web-frontend's own args, neither of which is
            # `commonArgs` itself, so it's listed again here explicitly.
            protobuf
          ]
          # The `ffmpeg` CLI on PATH: `ffmpegPackages` are only build
          # inputs here (libs/headers), and lib-gstreamer's tests/poster.rs
          # shells out to `ffmpeg` (testsrc + libx264 + aac) for its
          # fixture -- the minimal GStreamer set has no videotestsrc/AAC
          # encoder to do it instead.
          ++ ffmpegPackages;
        };
      }
    );
}
