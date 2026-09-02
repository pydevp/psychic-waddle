# next_file_browser-ci

Dependency-cache warmer for `next_file_browser`, which is developed
against a self-hosted git remote and never pushed to GitHub. This repo
holds **only**:

- the workspace `Cargo.toml` / `Cargo.lock`
- `flake.nix` / `flake.lock`
- each crate's `Cargo.toml`, plus a one-line stub `src/main.rs` or
  `src/lib.rs` (cargo needs *something* there to parse the manifest --
  crane doesn't synthesize this itself)
- any crate's `build.rs`, copied verbatim (cargo actually runs these
  during a dependency build; today the only one is
  `workspace-hackari`'s, a trivial `fn main() {}`)

No application logic is present. GitHub Actions (`.github/workflows/build.yml`)
runs `nix build .#cargo-deps-ffmpeg .#cargo-deps-frontend`, which is
crane's `buildDepsOnly` -- it only compiles the third-party dependency
graph from `Cargo.lock` -- and pushes the result to Cachix via
`cachix-action`. The real crates (with real source) are built and
pushed to the same Cachix cache locally, from the machine that actually
holds the source; this repo just pre-warms the slow, non-proprietary
dependency layer so those local builds are fast.

## Updating

This repo is regenerated, never hand-edited. From the main repo:

```sh
./scripts/sync-ci-deps.sh
cd ../next_file_browser-ci
git add -A && git commit -m "sync manifests" && git push
```

## One-time GitHub setup

1. Create this repo on GitHub (public is fine -- nothing sensitive lives
   here) and add it as `origin`.
2. In its Settings -> Secrets and variables -> Actions:
   - Secret `CACHIX_AUTH_TOKEN` -- an auth token from
     <https://app.cachix.org>, scoped to write to your cache.
   - Variable `CACHIX_CACHE_NAME` -- your Cachix cache name.
