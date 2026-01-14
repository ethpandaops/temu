# Temu

Automated patch management and build system for integrating Xatu Sidecar observability into Teku.

## Overview

Temu is a patch management system that integrates [Xatu Sidecar](https://github.com/ethpandaops/xatu-sidecar) observability into the [Teku](https://github.com/consensys/teku) Ethereum consensus client. It maintains patches that inject the Xatu plugin module into Teku builds, enabling enhanced network monitoring and metrics collection for the [Xatu](https://github.com/ethpandaops/xatu) data collection pipeline.

### Key Features

- **Xatu Sidecar Integration**: Seamlessly adds Xatu Sidecar observability capabilities to Teku
- **Plugin-based Architecture**: Clean separation using Teku's plugin system
- **JNA-based FFI**: Java Native Access for efficient native library calls
- **Patch Management**: Maintains patches for different Teku versions (branches, tags, commits)
- **Automated Updates**: CI/CD workflows to keep patches current with upstream changes

## Directory Structure

```
temu/
├── .github/workflows/         # GitHub Actions workflows
│   ├── check-patches.yml      # Automated patch checking and updating
│   ├── add-patch.yml          # Manual patch addition workflow
│   └── list-patches.yml       # List all available patches
├── plugins/                   # Plugin modules to be integrated
│   └── xatu/                  # Xatu plugin for Teku integration
│       ├── src/main/java/     # Java source files
│       └── build.gradle       # Gradle build configuration
├── patches/                   # Patch files organized by org/repo/ref
│   └── consensys/
│       └── teku/
│           └── master.patch   # Default patch for Teku
├── temu-build.sh              # Main build script
├── apply-temu-patch.sh        # Helper script to apply patches
├── save-patch.sh              # Script to generate patches from changes
└── example-xatu-config.yaml   # Xatu configuration file
```

## Scripts

### temu-build.sh

Main build script that handles the full workflow: clone, patch, build, and update patches.

```bash
# Usage
./temu-build.sh -r <org/repo> -b <branch/tag/commit> [--ci]

# Examples
./temu-build.sh -r consensys/teku -b master
./temu-build.sh -r consensys/teku -b 24.10.0
./temu-build.sh -r consensys/teku -b a1b2c3d

# CI mode (non-interactive, auto-approves changes)
./temu-build.sh -r consensys/teku -b master --ci
```

### apply-temu-patch.sh

Applies the Temu patch (plugins/xatu module + patch file) to a Teku repository.

```bash
# Usage
./apply-temu-patch.sh <org/repo> <branch> [target_dir]

# Examples
./apply-temu-patch.sh consensys/teku master
./apply-temu-patch.sh consensys/teku master /path/to/teku
```

### save-patch.sh

Generates a clean patch from modifications made to a Teku repository.

```bash
# Usage
./save-patch.sh [-r REPO] [-b BRANCH] [TARGET_DIR]

# Examples
./save-patch.sh                                    # Uses defaults
./save-patch.sh -r consensys/teku -b master teku
./save-patch.sh --ci teku                          # CI mode
```

## Usage

### Building a patched Teku

```bash
# Clone and build with default settings (consensys/teku master)
./temu-build.sh -r consensys/teku -b master

# The built binary will be at teku/build/install/teku/bin/teku
```

### Running Teku with Xatu

```bash
cd teku

# Option 1: CLI flag
./build/install/teku/bin/teku --xatu-config ../example-xatu-config.yaml

# Option 2: Environment variable
XATU_CONFIG=../example-xatu-config.yaml ./build/install/teku/bin/teku

# Option 3: System property
java -Dxatu.config=../example-xatu-config.yaml -jar build/libs/teku.jar
```

### Building a Docker Image

To build a local Docker image with Temu patches:

```bash
# First, build the patched Teku
./temu-build.sh -r consensys/teku -b master

# Then build the Docker image
cd teku && ./gradlew localDocker
```

This creates a `local/teku:develop-jdk21` Docker image that can be used with container orchestration tools.

### Running with Kurtosis

Temu can be run with [Kurtosis](https://www.kurtosis.com/) using the [ethereum-package](https://github.com/ethpandaops/ethereum-package).

Create a `config.yaml`:

```yaml
extra_files:
  xatu.yaml: |
    log_level: info
    processor:
      name: temu-node
      outputs:
        - name: stdout
          type: stdout
      ethereum:
        implementation: teku
        genesis_time: 0
        seconds_per_slot: 12
        slots_per_epoch: 32
        network:
          name: unknown
          id: 0
      client:
        name: temu
        version: 1.0.0

participants:
  - el_type: geth
    cl_type: teku
    cl_image: local/teku:develop-jdk21
    cl_extra_env_vars:
      XATU_CONFIG: /config/xatu.yaml
    cl_extra_mounts:
      /config: xatu.yaml
```

Run the enclave:

```bash
kurtosis run github.com/ethpandaops/ethereum-package --args-file config.yaml
```

### Customizing native library location

```bash
java -Dxatu.sidecar.library.path=/custom/path/libxatu.so -jar teku.jar
```

## Configuration

Example Xatu configuration (`example-xatu-config.yaml`):

```yaml
log_level: info
processor:
  name: temu-node
  outputs:
    - name: xatu-server
      type: xatu
      config:
        address: localhost:8080
        tls: false
        maxQueueSize: 500000
        batchTimeout: 1s
        exportTimeout: 15s
        maxExportBatchSize: 1000
        workers: 5
  ethereum:
    implementation: teku
    genesis_time: 0  # Overridden by Teku at runtime
    seconds_per_slot: 12
    slots_per_epoch: 32
    network:
      name: unknown  # Can be set for identification purposes
      id: 0
  client:
    name: temu
    version: 1.0.0
  # ntpServer: time.google.com
```

For simple stdout logging (useful for testing):

```yaml
log_level: info
processor:
  name: temu-node
  outputs:
    - name: stdout
      type: stdout
  ethereum:
    implementation: teku
    genesis_time: 0
    seconds_per_slot: 12
    slots_per_epoch: 32
    network:
      name: unknown
      id: 0
  client:
    name: temu
    version: 1.0.0
```

## Architecture

Temu uses a plugin-based architecture to integrate Xatu with Teku:

1. **Core Changes**: Minimal modifications to Teku core:
   - Event system extensions for gossip message notifications
   - Plugin initialization hooks

2. **Xatu Plugin**: Complete observability implementation:
   - Subscribes to gossip message events via EventChannels
   - Uses JNA to call into libxatu.so native library
   - Handles event batching and delivery

3. **Native Library**: libxatu.so (from xatu-sidecar):
   - Provides efficient event processing
   - Handles network delivery to Xatu server

## Contributing

1. Make changes to the Teku source in the `teku/` directory
2. Run `./save-patch.sh` to generate an updated patch
3. Test with `./temu-build.sh -r consensys/teku -b master`
4. Submit a PR with the updated patch file

## License

MIT License - see LICENSE file for details.
