# Temu

Patch-based overlay for integrating [Xatu Sidecar](https://github.com/ethpandaops/xatu-sidecar) observability into [Teku](https://github.com/consensys/teku).

## Overview

Temu uses a **patch + overlay** approach instead of maintaining a full fork. The repo stores only custom code and small patches; upstream Teku is cloned fresh each build.

### Repository Structure

```
temu/
├── plugins/                      # Custom code (copied into upstream clone)
│   └── xatu/                     # Xatu Sidecar plugin for Teku integration
├── patches/
│   └── consensys/teku/
│       └── master.patch          # Base patch: gossip hooks, xatu init, CLI flag
├── ci/
│   └── disable-upstream-workflows.sh
├── .github/workflows/
│   ├── check-patches.yml         # Daily: verify patches apply + build
│   ├── docker.yml                # On push/release: build + push Docker image
│   └── validate-patches.yml      # On PR: validate patch file structure
├── scripts/
│   ├── temu-build.sh             # Full orchestrator: clone -> patch -> build
│   ├── apply-temu-patch.sh       # Apply patches + plugin overlay + deps
│   ├── save-patch.sh             # Regenerate patches from modified clone
│   └── validate-patch.sh         # Patch file structural validation
├── example-xatu-config.yaml      # Xatu configuration template
└── .gitignore                    # Ignore teku/ working directory
```

## Quick Start

### Build

```bash
# Full build: clone upstream -> apply patches -> build binary
./scripts/temu-build.sh -r consensys/teku -b master

# The binary will be at teku/build/install/teku/bin/teku
```

### Docker

```bash
# Prepare patched source (skip local build, let Docker handle it)
./scripts/temu-build.sh -r consensys/teku -b master --skip-build

# Build Docker image using Teku's Gradle Docker task
cd teku && ./gradlew distDocker

# Tag for your registry
docker tag consensys/teku:develop ethpandaops/temu:latest
```

### Run

```bash
cd teku

# Option 1: CLI flag
./build/install/teku/bin/teku --xatu-config /path/to/xatu-config.yaml

# Option 2: Environment variable
XATU_CONFIG=/path/to/xatu-config.yaml ./build/install/teku/bin/teku

# Option 3: System property
java -Dxatu.config=/path/to/xatu-config.yaml -jar build/libs/teku.jar
```

The configuration file should be based on [`example-xatu-config.yaml`](example-xatu-config.yaml).

## Scripts

| Script | Purpose |
|---|---|
| `temu-build.sh` | Full orchestrator: clone upstream, apply patches + plugin overlay, build |
| `apply-temu-patch.sh` | Apply patches to an existing teku clone + copy plugin + deps |
| `save-patch.sh` | Regenerate patches from a modified teku clone |
| `validate-patch.sh` | Validate patch file structure (hunk counts, etc.) |
| `disable-upstream-workflows.sh` | Rename upstream CI workflows to `.disabled` |

### temu-build.sh

```bash
./scripts/temu-build.sh -r <org/repo> -b <branch> [-c <commit>] [--ci] [--skip-build]
```

**Options:**
- `-r, --repo`: Repository in format `org/repo`
- `-b, --branch`: Branch name, tag, or commit hash
- `-c, --commit`: Pin to specific upstream commit SHA
- `--ci`: CI mode (non-interactive, auto-clean, auto-update patches)
- `--skip-build`: Skip `./gradlew installDist`, exit after applying patches (for Docker CI)

## How It Works

### Custom Code as Overlay

`plugins/xatu/` is the Xatu Sidecar plugin module, **copied** into the upstream clone at build time. It is never part of the patch.

### CI Workflow Disabling

Instead of patching workflow renames, a simple script renames all non-temu workflows to `.disabled`.

### Docker via Gradle

The Docker image is built using Teku's own `./gradlew distDocker` task. The patch modifies the upstream Dockerfiles to include libxatu.so in the image. No custom Dockerfile is needed.

### Patches

The actual patch surface is minimal (Java source only):
- **`master.patch`**: Adds EventChannels for gossip message notifications, xatu plugin initialization hooks, `--xatu-config` CLI flag, transport peer ID support, build dependencies, and Docker image libxatu.so integration

## Development

### Adding a new feature

#### New files (overlay)

Self-contained new code goes in `plugins/xatu/`. These files are copied verbatim into the upstream clone at build time.

```bash
vim plugins/xatu/src/main/java/tech/pegasys/teku/plugin/xatu/NewFeature.java
git add plugins/
git commit -m "feat: add new feature"
```

#### Modifying upstream files (patch)

If your feature requires changing existing upstream Java source:

```bash
# 1. Build to get the working upstream clone
./scripts/temu-build.sh -r consensys/teku -b master

# 2. Edit upstream files in the clone
vim teku/networking/eth2/src/main/java/.../Eth2TopicHandler.java

# 3. Regenerate the patch
./scripts/save-patch.sh -r consensys/teku -b master teku

# 4. Commit the updated patch
git add patches/
git commit -m "feat: add new-feature wiring to base patch"
```

### Fixing a patch conflict

When upstream changes the same lines our patches touch, `apply-temu-patch.sh` will fail. To fix:

```bash
# 1. Run the build -- it will show exactly which hunks failed
./scripts/temu-build.sh -r consensys/teku -b master

# 2. Fix the conflicts in the upstream clone
vim teku/networking/eth2/src/main/java/.../Eth2TopicHandler.java

# 3. Regenerate the patch
./scripts/save-patch.sh -r consensys/teku -b master teku

# 4. Commit the updated patch
git add patches/
git commit -m "fix: update patches for upstream changes"
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

## CI

| Workflow | Trigger | What it does |
|---|---|---|
| `check-patches.yml` | Daily (cron) | Clones upstream, applies patches, builds. Auto-commits if patches needed updating |
| `docker.yml` | Push to master / release | Builds + pushes multi-arch Docker image to `ethpandaops/temu:<tag>` |
| `validate-patches.yml` | PR | Validates patch file structure (hunk counts, etc.) |

## Requirements

- Java 21+ (Eclipse Temurin recommended)
- Gradle (wrapper included in Teku)
- Git
- Bash
- GitHub CLI (`gh`) for release creation in CI
