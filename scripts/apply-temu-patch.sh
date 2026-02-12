#!/bin/bash

set -e

# This script applies the temu patches + plugin overlay to an upstream teku clone
# Usage: ./apply-temu-patch.sh <org/repo> <branch> [target_dir]

if [ $# -lt 2 ]; then
    echo "Usage: $0 <org/repo> <branch> [target_dir]"
    echo "Example: $0 consensys/teku master"
    echo "         $0 consensys/teku master /path/to/teku"
    exit 1
fi

# Parse org/repo
IFS='/' read -ra REPO_PARTS <<< "$1"
if [ ${#REPO_PARTS[@]} -ne 2 ]; then
    echo "Error: Repository must be in format 'org/repo'"
    exit 1
fi
ORG="${REPO_PARTS[0]}"
REPO="${REPO_PARTS[1]}"
BRANCH="$2"
TARGET_DIR="${3:-teku}"

# Get the script's directory and repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Change to target directory
if [ ! -d "$TARGET_DIR" ]; then
    echo "Error: Target directory '$TARGET_DIR' does not exist"
    exit 1
fi

cd "$TARGET_DIR"

# Check if we're in a git repository
if [ ! -d ".git" ]; then
    echo "Error: Target directory is not a git repository"
    exit 1
fi

# Find patch file (no fallback)
PATCH_FILE="$REPO_ROOT/patches/$ORG/$REPO/$BRANCH.patch"
if [ ! -f "$PATCH_FILE" ]; then
    echo "Error: Patch not found at patches/$ORG/$REPO/$BRANCH.patch"
    exit 1
fi

echo "Patch file: $(basename "$PATCH_FILE")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Source the shared patch validation function
source "$REPO_ROOT/scripts/validate-patch.sh"

# Validate patch file structure
echo ""
echo -e "${BLUE}=== Applying patch: $(basename "$PATCH_FILE") ===${NC}"
echo -e "${BLUE}  Validating patch file structure...${NC}"
if ! validate_patch_file "$PATCH_FILE"; then
    echo -e "${RED}Patch file is corrupt or malformed${NC}"
    echo -e "${RED}  Please regenerate the patch using save-patch.sh${NC}"
    exit 1
fi
echo -e "${GREEN}  Patch file structure is valid${NC}"

# Apply patch
PATCH_APPLIED=false
if git apply --check "$PATCH_FILE" 2>/dev/null; then
    echo -e "${GREEN}  Patch check passed, applying...${NC}"
    git apply "$PATCH_FILE"
    echo -e "${GREEN}  Patch applied successfully${NC}"
    PATCH_APPLIED=true
elif git apply --check --reverse "$PATCH_FILE" 2>/dev/null; then
    echo -e "${GREEN}  Patch is already applied (verified by reverse check)${NC}"
else
    # Try 3-way merge
    echo -e "${YELLOW}  Direct apply failed, trying 3-way merge...${NC}"
    if git apply --3way "$PATCH_FILE" 2>/dev/null; then
        echo -e "${GREEN}  Patch applied with 3-way merge${NC}"
        PATCH_APPLIED=true
    else
        echo -e "${RED}  Failed to apply patch: $(basename "$PATCH_FILE")${NC}"
        echo ""
        echo "Attempting apply with rejects for diagnostics..."
        git apply --reject "$PATCH_FILE" 2>&1 || true

        REJECT_FILES=$(find . -name "*.rej" 2>/dev/null | sort)
        if [ -n "$REJECT_FILES" ]; then
            echo ""
            echo -e "${YELLOW}=== Patch Conflict Details ===${NC}"
            for reject in $REJECT_FILES; do
                echo -e "${RED}  Conflict in: ${reject%.rej}${NC}"
                cat "$reject" | sed 's/^/    /'
                echo ""
            done
            find . -name "*.rej" -delete 2>/dev/null
            find . -name "*.orig" -delete 2>/dev/null
        fi

        echo -e "${RED}Common causes:${NC}"
        echo "  - The target branch has diverged from when patch was created"
        echo "  - Recent commits modified the same lines"
        echo ""
        CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "detached")
        LATEST_COMMIT=$(git log -1 --oneline)
        echo -e "${BLUE}Current state:${NC}"
        echo "  Branch: $CURRENT_BRANCH"
        echo "  Latest: $LATEST_COMMIT"
        exit 1
    fi
fi

# Copy plugin files
echo ""
echo -e "${BLUE}=== Copying plugin files ===${NC}"

if [ ! -d "$REPO_ROOT/plugins/xatu" ]; then
    echo -e "${RED}Error: xatu plugin not found at $REPO_ROOT/plugins/xatu${NC}"
    exit 1
fi

if [ -d "plugins/xatu" ]; then
    echo -e "${YELLOW}  plugins/xatu/ directory already exists, replacing...${NC}"
    rm -rf plugins/xatu
fi

# Copy plugin source only (exclude build artifacts)
mkdir -p plugins/xatu
cp "$REPO_ROOT/plugins/xatu/build.gradle" plugins/xatu/
cp -r "$REPO_ROOT/plugins/xatu/src" plugins/xatu/
echo -e "${GREEN}  Copied plugins/xatu/${NC}"

# Download libxatu.so if not present
echo ""
echo -e "${BLUE}=== Downloading libxatu ===${NC}"

XATU_SIDECAR_VERSION="v0.0.6"
if [ ! -f "libxatu.so" ]; then
    echo -e "${BLUE}  Downloading libxatu.so (${XATU_SIDECAR_VERSION})...${NC}"

    ARCH=$(uname -m)
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')

    case "$ARCH" in
        x86_64) PLATFORM_ARCH="amd64" ;;
        aarch64|arm64) PLATFORM_ARCH="arm64" ;;
        *) echo -e "${RED}Unsupported architecture: $ARCH${NC}"; exit 1 ;;
    esac

    case "$OS" in
        linux) PLATFORM_OS="linux" ;;
        darwin) PLATFORM_OS="darwin" ;;
        *) echo -e "${RED}Unsupported OS: $OS${NC}"; exit 1 ;;
    esac

    PLATFORM="${PLATFORM_OS}_${PLATFORM_ARCH}"
    VERSION_NUM="${XATU_SIDECAR_VERSION#v}"
    URL="https://github.com/ethpandaops/xatu-sidecar/releases/download/${XATU_SIDECAR_VERSION}/xatu-sidecar_${VERSION_NUM}_${PLATFORM}.tar.gz"

    echo -e "${BLUE}  URL: $URL${NC}"
    curl -sL "$URL" | tar -xzf - --wildcards "*.so" "*.dylib" "*.h" 2>/dev/null || \
    curl -sL "$URL" | tar -xzf - libxatu.so libxatu.h 2>/dev/null || \
    curl -sL "$URL" | tar -xzf - libxatu.dylib libxatu.h 2>/dev/null

    if [ -f "libxatu.so" ] || [ -f "libxatu.dylib" ]; then
        echo -e "${GREEN}  Downloaded libxatu library${NC}"
    else
        echo -e "${YELLOW}  Warning: Could not download libxatu.so, you may need to download it manually${NC}"
    fi
else
    echo -e "${GREEN}  libxatu.so already exists, skipping download${NC}"
fi

# Append .gitignore entries for xatu build artifacts
echo ""
echo -e "${BLUE}=== Updating .gitignore ===${NC}"
if ! grep -q '/libxatu.so' .gitignore 2>/dev/null; then
    echo "" >> .gitignore
    echo "# Xatu build artifacts" >> .gitignore
    echo "/libxatu.so" >> .gitignore
    echo "/libxatu.h" >> .gitignore
    echo -e "${GREEN}  Added xatu build artifact entries to .gitignore${NC}"
else
    echo -e "${GREEN}  .gitignore already has xatu entries${NC}"
fi

# Disable upstream workflows
echo ""
echo -e "${BLUE}=== Disabling upstream workflows ===${NC}"
"$REPO_ROOT/ci/disable-upstream-workflows.sh"

# Final summary
echo ""
if [ "$PATCH_APPLIED" = false ]; then
    echo -e "${YELLOW}=========================================${NC}"
    echo -e "${YELLOW}  Temu patch was already applied${NC}"
    echo -e "${YELLOW}=========================================${NC}"
else
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}  Successfully applied temu patch!${NC}"
    echo -e "${GREEN}=========================================${NC}"
fi
echo -e "  ${GREEN}Plugin files copied${NC}"
echo -e "  ${GREEN}Upstream workflows disabled${NC}"
