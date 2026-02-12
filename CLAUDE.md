# Temu

This project contains three main components:

- `patches/${github_org}/${github_repo}/${branch/tag/commit}.patch` - Patch files to apply to Teku upstream repo
- `plugins/xatu` - The xatu plugin module for the [xatu-sidecar](https://github.com/ethpandaops/xatu-sidecar) integration
- `ci/` - CI helpers (disable upstream workflows)

The goal of this project is to inject the xatu-sidecar into the Teku build process, by applying a patch file and copying the xatu plugin module.

## Project structure

```
patches/         - Patches (Java source + build config diffs)
plugins/xatu/    - Xatu plugin module (copied into Teku during apply)
ci/              - Workflow helpers (disable upstream workflows)
scripts/         - Build, apply, save, and validate scripts
```

## How is this repo used?

1. `scripts/apply-temu-patch.sh` applies patches, copies plugins/xatu, downloads libxatu.so, and disables upstream workflows
2. `scripts/temu-build.sh` orchestrates clone + apply + build (supports `--skip-build` for Docker CI)
3. `scripts/save-patch.sh` strips plugin/build artifacts and generates a clean patch
4. Docker images are built using Teku's built-in `./gradlew distDocker` (produces `consensys/teku:develop`), then tagged and pushed

## Testing with Kurtosis

For end-to-end testing with a local multi-client testnet:

1. Build Docker image: `cd teku && ./gradlew distDocker` (produces `consensys/teku:develop`)
2. Run: `kurtosis run github.com/ethpandaops/ethereum-package --args-file kurtosis-config.yaml --enclave temu`
3. View logs: `kurtosis service logs temu cl-1-teku-nethermind --follow`
4. Cleanup: `kurtosis enclave rm -f temu`

The `kurtosis-config.yaml` configures a 2-node testnet (temu + lighthouse) with nethermind EL, fast fork schedule, and dora explorer. The xatu config is inlined via `extra_files` so events are visible in `kurtosis service logs`.
