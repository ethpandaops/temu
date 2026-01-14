# Temu

This project contains two main components:

- @patches/${github_org}/${github_repo}/${branch/tag/commit}.patch - A patch file to apply to Teku upstream repo
- @plugins/xatu - The xatu plugin module for the [xatu-sidecar](https://github.com/ethpandaops/xatu-sidecar) integration

The goal of this project is to inject the xatu-sidecar into the Teku build process, by applying a patch file and copying the xatu plugin module.

## How is this repo used?

- The patch needs to be applied to the target Teku repo, if there is no patch file found, then the default is used @patches/consensys/teku/master.patch
- The @plugins/xatu module is copied to the target Teku's plugins directory
- libxatu.so (the xatu-sidecar FFI library) is downloaded to the Teku root
- `./gradlew installDist` should be run to build the Teku binary

## Architecture

Unlike Lighthouse (Rust), Teku is Java-based and uses JNA (Java Native Access) to call into the libxatu.so shared library.

The integration is plugin-based:
- `plugins/xatu/` contains the Java plugin code
- The plugin uses EventChannels to receive gossip messages
- JNA provides the FFI bridge to libxatu.so

## Key Files

- `apply-temu-patch.sh` - Apply patch and copy plugin to Teku
- `temu-build.sh` - Clone, patch, and build Teku
- `save-patch.sh` - Generate patch from modified Teku
- `example-xatu-config.yaml` - Sample Xatu configuration
