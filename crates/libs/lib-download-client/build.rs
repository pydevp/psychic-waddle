//! Compiles `proto/download.proto` into `src/lib.rs`'s `pub mod proto`
//! (via `include!` — see `tonic_prost_build`'s generated layout).
//!
//! Needs a `protoc` on `$PATH` (or `$PROTOC` pointing straight at the
//! binary) — this crate doesn't vendor one. In the nix devShell/build,
//! that's `pkgs.protobuf` (see flake.nix); outside it, install `protoc`
//! yourself or `export PROTOC=$(which protoc)`.

fn main() -> Result<(), Box<dyn std::error::Error>> {
    tonic_prost_build::configure()
        .build_server(true)
        .build_client(true)
        .compile_protos(&["proto/download.proto"], &["proto"])?;
    Ok(())
}
