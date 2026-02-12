# Temu

This project contains three main components:

- `patches/${github_org}/${github_repo}/${branch/tag/commit}.patch` - Patch files (Java source only) to apply to Teku upstream repo
- `plugins/xatu` - The xatu plugin module for the [xatu-sidecar](https://github.com/ethpandaops/xatu-sidecar) integration
- `ci/` - Dockerfile and CI helpers (copied over upstream files during apply)

The goal of this project is to inject the xatu-sidecar into the Teku build process, by applying a patch file and copying the xatu plugin module.

## Project structure

```
patches/         - Slim patches (only Java source diffs)
plugins/xatu/    - Xatu plugin module (copied into Teku during apply)
ci/              - Dockerfile.ethpandaops and workflow helpers
scripts/         - Build, apply, save, and validate scripts
```

## How is this repo used?

1. `scripts/apply-temu-patch.sh` applies patches, copies plugins/xatu, copies ci/Dockerfile.ethpandaops, downloads libxatu.so, and disables upstream workflows
2. `scripts/temu-build.sh` orchestrates clone + apply + build (supports `--skip-build` for Docker CI)
3. `scripts/save-patch.sh` strips plugin/CI/build artifacts and generates a clean patch
