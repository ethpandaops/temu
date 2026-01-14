#!/bin/bash

set -e

# This script applies the temu patch (plugins/xatu module + patch file) to a Teku repository
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
TARGET_DIR="${3:-teku}"  # Default to "teku" if not specified

# Get the script's directory (where patches/ and plugins/ are located)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Find the appropriate patch file with fallback logic
find_patch_file() {
    local org="$1"
    local repo="$2"
    local branch="$3"

    # Try exact match first
    local exact_patch="$SCRIPT_DIR/patches/$org/$repo/$branch.patch"
    if [ -f "$exact_patch" ]; then
        echo "$exact_patch"
        return 0
    fi

    # Fallback to default
    local default_patch="$SCRIPT_DIR/patches/consensys/teku/master.patch"
    if [ -f "$default_patch" ]; then
        echo "Patch file not found at patches/$org/$repo/$branch.patch, using default..." >&2
        echo "$default_patch"
        return 0
    fi

    return 1
}

# Find the patch file
PATCH_FILE=$(find_patch_file "$ORG" "$REPO" "$BRANCH")
if [ -z "$PATCH_FILE" ]; then
    echo "Error: No patch file found"
    exit 1
fi

echo "Using patch file: $PATCH_FILE"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Apply the patch with better error handling
echo -e "${BLUE}Applying patch...${NC}"

# First check if patch can be applied
echo -e "${BLUE}Running patch check...${NC}"
echo -e "${BLUE}  Current directory: $(pwd)${NC}"
echo -e "${BLUE}  Patch file: $PATCH_FILE${NC}"

# Run the patch check and capture both output and exit code
echo -e "${BLUE}  Running: git apply --check \"$PATCH_FILE\"${NC}"

# Try running without redirection first to see if it completes
if ! git apply --check "$PATCH_FILE" 2>&1; then
    PATCH_EXIT_CODE=1
    echo -e "${YELLOW}  Patch check failed, getting detailed error...${NC}"
    # Now capture the output for analysis
    PATCH_CHECK=$(git apply --check "$PATCH_FILE" 2>&1 || true)
else
    PATCH_EXIT_CODE=0
    PATCH_CHECK=""
fi

# If patch check failed, show the error immediately
if [ $PATCH_EXIT_CODE -ne 0 ]; then
    echo -e "${RED}Patch check failed with errors:${NC}"
    echo "$PATCH_CHECK"
fi

if [ $PATCH_EXIT_CODE -eq 0 ]; then
    # Patch can be applied cleanly
    echo -e "${GREEN}✓ Patch check passed, applying...${NC}"
    git apply "$PATCH_FILE"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Patch applied successfully${NC}"
    else
        echo -e "${RED}✗ Patch application failed unexpectedly${NC}"
        exit 1
    fi
else
    # Check if it's because patch is already applied
    echo -e "${YELLOW}⚠ Patch cannot be applied directly${NC}"

    # Check if this is because the patch is already partially or fully applied
    echo -e "${BLUE}Checking current state of patch application...${NC}"

    # Check for key indicators that the patch has been applied
    # Look for xatu plugin references in key files
    if grep -q "plugins:xatu" settings.gradle 2>/dev/null && \
       [ -d "plugins/xatu" ]; then
        echo -e "${GREEN}✓ Patch appears to be already applied (xatu plugin found)${NC}"
        echo -e "${BLUE}  Skipping patch application.${NC}"
        # Set a flag to indicate patch was already applied
        PATCH_ALREADY_APPLIED=true
    # Try reverse check to see if patch is fully applied
    elif git apply --check --reverse "$PATCH_FILE" 2>/dev/null; then
        echo -e "${GREEN}✓ Patch is already fully applied!${NC}"
        echo -e "${BLUE}  Skipping patch application.${NC}"
        # Set a flag to indicate patch was already applied
        PATCH_ALREADY_APPLIED=true
    else
        # Patch has actual conflicts, show detailed info
        echo -e "${RED}Error: Failed to apply patch${NC}"
        echo ""

        # First, try to apply with rejects to see what specifically fails
        echo -e "${YELLOW}Analyzing patch conflicts...${NC}"
        git apply --reject "$PATCH_FILE" 2>/dev/null || true

        # Check for reject files and show them immediately
        REJECT_FILES=$(find . -name "*.rej" 2>/dev/null | sort)
        if [ -n "$REJECT_FILES" ]; then
            echo ""
            echo -e "${YELLOW}═══ Patch Conflict Details ═══${NC}"
            echo ""

            for reject in $REJECT_FILES; do
                ORIG_FILE="${reject%.rej}"
                echo -e "${RED}━━━ Conflict in: $ORIG_FILE ━━━${NC}"

                # Show the full contents of the .rej file
                echo -e "${YELLOW}Failed patch hunk:${NC}"
                cat "$reject" | sed 's/^/  /'
                echo ""
            done

            # Clean up the reject files before trying 3-way merge
            find . -name "*.rej" -delete 2>/dev/null
            find . -name "*.orig" -delete 2>/dev/null
        fi

        # Try with 3-way merge
        echo -e "${YELLOW}Attempting 3-way merge...${NC}"
        if git apply --3way "$PATCH_FILE" 2>/dev/null; then
            echo -e "${GREEN}✓ Patch applied with 3-way merge${NC}"
        else
            # Show what's failing
            echo -e "${RED}Conflicts detected. Analyzing...${NC}"
            echo ""

            # Count total hunks
            TOTAL_HUNKS=$(grep -c "^@@" "$PATCH_FILE" 2>/dev/null || echo 0)
            echo -e "${BLUE}Total hunks in patch: ${TOTAL_HUNKS}${NC}"

            # Try to apply with rejects to see what works/fails
            APPLY_OUTPUT=$(git apply --reject "$PATCH_FILE" 2>&1)

            # Parse the output
            echo "$APPLY_OUTPUT" | while IFS= read -r line; do
                if [[ "$line" =~ "Applied patch" ]]; then
                    echo -e "${GREEN}✓ $line${NC}"
                elif [[ "$line" =~ "Hunk #".*"succeeded" ]]; then
                    echo -e "${GREEN}  ✓ $line${NC}"
                elif [[ "$line" =~ "error:" ]] || [[ "$line" =~ "Rejected" ]]; then
                    echo -e "${RED}  ✗ $line${NC}"
                elif [[ "$line" =~ "Applying patch" ]]; then
                    echo -e "${BLUE}→ $line${NC}"
                else
                    echo "  $line"
                fi
            done

            echo ""

            # Check for reject files
            REJECT_FILES=$(find . -name "*.rej" 2>/dev/null | sort)
            if [ -n "$REJECT_FILES" ]; then
                echo -e "${YELLOW}═══ Detailed Reject Analysis ═══${NC}"
                echo ""

                for reject in $REJECT_FILES; do
                    ORIG_FILE="${reject%.rej}"
                    echo -e "${RED}━━━ Conflict in: $ORIG_FILE ━━━${NC}"

                    # Show the full contents of the .rej file
                    echo -e "${YELLOW}Failed patch hunk:${NC}"
                    cat "$reject" | sed 's/^/  /'

                    # Try to show context from the actual file
                    if [ -f "$ORIG_FILE" ]; then
                        # Extract line numbers from the reject file
                        LINE_INFO=$(grep "^@@" "$reject" | head -1)
                        if [[ "$LINE_INFO" =~ @@[[:space:]]-[0-9]+,[0-9]+[[:space:]]\+([0-9]+) ]]; then
                            TARGET_LINE="${BASH_REMATCH[1]}"
                            echo ""
                            echo -e "${BLUE}Current file content around line $TARGET_LINE:${NC}"
                            # Show 5 lines before and after the target line
                            START_LINE=$((TARGET_LINE - 5))
                            END_LINE=$((TARGET_LINE + 5))
                            if [ $START_LINE -lt 1 ]; then START_LINE=1; fi
                            sed -n "${START_LINE},${END_LINE}p" "$ORIG_FILE" | nl -v $START_LINE | sed 's/^/  /'
                        fi
                    fi
                    echo ""
                done

                echo ""
                echo -e "${YELLOW}To fix:${NC}"
                echo "  1. Review the .rej files"
                echo "  2. Manually apply failed hunks"
                echo "  3. Clean up: find . -name '*.rej' -delete"
            fi

            echo ""
            echo -e "${RED}Common causes:${NC}"
            echo "  - The patch is already partially applied"
            echo "  - The repository has uncommitted changes"
            echo "  - The target branch has diverged from when patch was created"
            echo "  - Recent commits modified the same lines"

            # Show current branch info
            echo ""
            CURRENT_BRANCH=$(git branch --show-current)
            LATEST_COMMIT=$(git log -1 --oneline)
            echo -e "${BLUE}Current state:${NC}"
            echo "  Branch: $CURRENT_BRANCH"
            echo "  Latest: $LATEST_COMMIT"

            exit 1
        fi
    fi
fi

# Copy the plugins/xatu module
echo -e "${BLUE}Copying plugins/xatu module...${NC}"
if [ ! -d "$SCRIPT_DIR/plugins/xatu" ]; then
    echo -e "${RED}Error: xatu plugin not found at $SCRIPT_DIR/plugins/xatu${NC}"
    exit 1
fi

# Create plugins directory if it doesn't exist
mkdir -p plugins

# Check if plugins/xatu already exists
if [ -d "plugins/xatu" ]; then
    echo -e "${YELLOW}  plugins/xatu/ directory already exists, replacing...${NC}"
    rm -rf plugins/xatu
fi

# Copy plugin source only (exclude build artifacts to ensure clean gradle build)
mkdir -p plugins/xatu
cp "$SCRIPT_DIR/plugins/xatu/build.gradle" plugins/xatu/
cp -r "$SCRIPT_DIR/plugins/xatu/src" plugins/xatu/

# Download libxatu.so if not present
XATU_SIDECAR_VERSION="v0.0.5"
if [ ! -f "libxatu.so" ]; then
    echo -e "${BLUE}Downloading libxatu.so (${XATU_SIDECAR_VERSION})...${NC}"

    # Detect platform
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

    echo -e "${BLUE}  Downloading from: $URL${NC}"

    # Download and extract
    curl -sL "$URL" | tar -xzf - --wildcards "*.so" "*.dylib" "*.h" 2>/dev/null || \
    curl -sL "$URL" | tar -xzf - libxatu.so libxatu.h 2>/dev/null || \
    curl -sL "$URL" | tar -xzf - libxatu.dylib libxatu.h 2>/dev/null

    if [ -f "libxatu.so" ] || [ -f "libxatu.dylib" ]; then
        echo -e "${GREEN}  ✓ Downloaded libxatu library${NC}"
    else
        echo -e "${YELLOW}  Warning: Could not download libxatu.so, you may need to download it manually${NC}"
    fi
else
    echo -e "${BLUE}  libxatu.so already exists, skipping download${NC}"
fi

# Final success message
echo ""
if [ "$PATCH_ALREADY_APPLIED" = true ]; then
    echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  Temu patch was already applied${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
    echo -e "  ${BLUE}→ Patch location:${NC} $PATCH_FILE"
    echo -e "  ${BLUE}→ plugins/xatu refreshed at:${NC} $(pwd)/plugins/xatu"
else
    echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Successfully applied temu patch!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}✓ Applied patch:${NC} $PATCH_FILE"
    echo -e "  ${GREEN}✓ Copied plugins/xatu to:${NC} $(pwd)/plugins/xatu"
fi
