//! Compiles every `.proto` under `proto/` into `src/lib.rs`'s
//! `pub mod transcode`/`assets`/`download` (via `include!` — see
//! `tonic_prost_build`'s generated `mod.rs`-per-package layout, one
//! `<package>.rs` per `package` line in the `.proto`).
//!
//! Needs a `protoc` on `$PATH` (or `$PROTOC` pointing straight at the
//! binary) — this crate doesn't vendor one. In the nix devShell/build,
//! that's `pkgs.protobuf` (see flake.nix); outside it, install `protoc`
//! yourself or `export PROTOC=$(which protoc)`.

fn main() -> Result<(), Box<dyn std::error::Error>> {
    tonic_prost_build::configure()
        .build_server(true)
        .build_client(true)
        .compile_protos(
            &[
                "proto/transcode.proto",
                "proto/assets.proto",
                "proto/download.proto",
            ],
            &["proto"],
        )?;
    Ok(())
}
