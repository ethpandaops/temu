#!/bin/bash

# save-patch.sh - Generate a clean patch from manual changes to teku
# Usage: ./save-patch.sh [-r REPO] [-b BRANCH] [TARGET_DIR]
#   -r REPO: GitHub org/repo (default: consensys/teku)
#   -b BRANCH: Branch/tag/commit (default: master)
#   TARGET_DIR: Directory to save patch from (default: teku)

set -e

# Default values
ORG_REPO="consensys/teku"
BRANCH="master"
TARGET_DIR="teku"
INTERACTIVE=true
CI_MODE=false
QUIET=false

# Parse command-line arguments
# Save original arguments
ORIG_ARGS=("$@")

# First, filter out --ci flag and set it
NEW_ARGS=()
for arg in "${ORIG_ARGS[@]}"; do
    if [ "$arg" = "--ci" ]; then
        CI_MODE=true
        INTERACTIVE=false
        QUIET=true
    else
        NEW_ARGS+=("$arg")
    fi
done

# Reset arguments without --ci for getopts
set -- "${NEW_ARGS[@]}"

# Now parse short options
while getopts "r:b:nhq" opt; do
    case $opt in
        r)
            ORG_REPO="$OPTARG"
            ;;
        b)
            BRANCH="$OPTARG"
            ;;
        n)
            INTERACTIVE=false
            ;;
        q)
            QUIET=true
            ;;
        h)
            echo "Usage: $0 [-r REPO] [-b BRANCH] [-n] [-q] [--ci] [TARGET_DIR]"
            echo "  -r REPO    GitHub org/repo (default: consensys/teku)"
            echo "  -b BRANCH  Branch/tag/commit (default: master)"
            echo "  -n         Non-interactive mode (skip preview prompt)"
            echo "  -q         Quiet mode (minimal output)"
            echo "  --ci       CI mode (non-interactive, quiet, return 2 if no changes)"
            echo "  TARGET_DIR Directory to save patch from (default: teku)"
            exit 0
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            exit 1
            ;;
    esac
done

# Shift to get positional arguments
shift $((OPTIND-1))

# Get target directory from positional argument if provided
if [ $# -gt 0 ]; then
    TARGET_DIR="$1"
fi

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Validate target directory
if [ ! -d "$TARGET_DIR" ]; then
    echo "Error: Target directory '$TARGET_DIR' does not exist"
    exit 1
fi

# Change to target directory
cd "$TARGET_DIR"

# Check if we're in a git repository
if [ ! -d ".git" ]; then
    echo "Error: Target directory is not a git repository"
    exit 1
fi

# Extract org and repo from the combined string
ORG=$(echo "$ORG_REPO" | cut -d'/' -f1)
REPO=$(echo "$ORG_REPO" | cut -d'/' -f2)

# Define patch file path
PATCH_DIR="$SCRIPT_DIR/patches/$ORG/$REPO"
PATCH_FILE="$PATCH_DIR/$BRANCH.patch"

if [ "$QUIET" = false ]; then
    echo "========================================="
    echo "  Save Patch Script (Temu)"
    echo "========================================="
    echo "Repository: $ORG_REPO"
    echo "Branch: $BRANCH"
    echo "Target directory: $(pwd)"
    echo "Patch file: $PATCH_FILE"
    echo ""
fi

# Step 1: Clean up - Remove plugins/xatu module if it exists (it's copied separately)
if [ -d "plugins/xatu" ]; then
    [ "$QUIET" = false ] && echo "-> Removing plugins/xatu directory (stored separately)..."
    rm -rf plugins/xatu
fi

# Step 2: Clean up - Remove libxatu.so and libxatu.h if present
if [ -f "libxatu.so" ] || [ -f "libxatu.h" ] || [ -f "libxatu.dylib" ]; then
    [ "$QUIET" = false ] && echo "-> Removing libxatu files..."
    rm -f libxatu.so libxatu.h libxatu.dylib
fi

# Step 3: Remove Gradle build artifacts from tracking
[ "$QUIET" = false ] && echo "-> Cleaning up build artifacts..."
rm -rf build .gradle */build 2>/dev/null || true

# Step 4: Remove any .rej or .orig files
[ "$QUIET" = false ] && echo "-> Cleaning up .rej and .orig files..."
find . -name "*.rej" -o -name "*.orig" | xargs rm -f 2>/dev/null || true

# Step 5: Check if there are any changes to save
if [ -z "$(git status --porcelain)" ]; then
    if [ "$CI_MODE" = true ]; then
        # In CI mode, exit with code 2 to indicate no changes (not an error, but different from success)
        [ "$QUIET" = false ] && echo "No changes to save"
        exit 2
    else
        echo ""
        echo "! No changes detected in the repository"
        echo "  Make your manual changes first, then run this script again"
        exit 1
    fi
fi

# Step 6: Show what will be included in the patch
if [ "$QUIET" = false ]; then
    echo ""
    echo "-> Changes to be saved in patch:"
    echo "--------------------------------"
    git status --short
    echo "--------------------------------"
    echo ""
fi

# Step 7: Create patch directory if it doesn't exist
mkdir -p "$PATCH_DIR"

# Step 8: Generate the patch (including new files)
[ "$QUIET" = false ] && echo "-> Generating patch..."

# First get modifications to tracked files
git diff --no-color --no-ext-diff > "$PATCH_FILE"

# Then add new files to the patch
for file in $(git status --porcelain | grep "^??" | cut -c4-); do
    # Skip certain files that shouldn't be in the patch
    case "$file" in
        libxatu.so|libxatu.h|libxatu.dylib|example-xatu-config.yaml|test-xatu.sh|XATU_REFACTORING.md|plugins/*)
            continue
            ;;
        *)
            # Add new file to patch
            echo "" >> "$PATCH_FILE"
            echo "diff --git a/$file b/$file" >> "$PATCH_FILE"
            echo "new file mode 100644" >> "$PATCH_FILE"
            echo "--- /dev/null" >> "$PATCH_FILE"
            echo "+++ b/$file" >> "$PATCH_FILE"
            line_count=$(wc -l < "$file")
            echo "@@ -0,0 +1,$line_count @@" >> "$PATCH_FILE"
            sed 's/^/+/' "$file" >> "$PATCH_FILE"
            ;;
    esac
done

# Step 9: Check if patch was created successfully
if [ ! -s "$PATCH_FILE" ]; then
    echo "Error: Failed to create patch or patch is empty"
    exit 1
fi

# Step 10: Show patch statistics
PATCH_LINES=$(wc -l < "$PATCH_FILE")
PATCH_SIZE=$(du -h "$PATCH_FILE" | cut -f1)
ADDED_LINES=$(grep -c "^+" "$PATCH_FILE" 2>/dev/null || echo 0)
REMOVED_LINES=$(grep -c "^-" "$PATCH_FILE" 2>/dev/null || echo 0)

if [ "$QUIET" = false ]; then
    echo ""
    echo "* Patch saved successfully!"
    echo ""
    echo "Patch statistics:"
    echo "  - File: $PATCH_FILE"
    echo "  - Size: $PATCH_SIZE"
    echo "  - Total lines: $PATCH_LINES"
    echo "  - Added lines: $ADDED_LINES"
    echo "  - Removed lines: $REMOVED_LINES"
    echo ""

    # Step 11: Provide next steps
    echo "Next steps:"
    echo "  1. Review the patch: less \"$PATCH_FILE\""
    echo "  2. Test applying it: ./apply-temu-patch.sh $ORG_REPO $BRANCH $TARGET_DIR"
    echo "  3. Build with it: ./temu-build.sh -r $ORG_REPO -b $BRANCH"
    echo ""
else
    # In quiet mode, just output the patch file path
    echo "$PATCH_FILE"
fi

# Step 12: Optionally show a preview of the patch
if [ "$INTERACTIVE" = true ]; then
    read -p "Would you like to preview the patch? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo ""
        echo "Patch preview (first 50 lines):"
        echo "================================"
        head -50 "$PATCH_FILE"
        if [ "$PATCH_LINES" -gt 50 ]; then
            echo ""
            echo "... (showing first 50 of $PATCH_LINES lines)"
            echo "Use 'less \"$PATCH_FILE\"' to view the full patch"
        fi
    fi
fi

# Step 13: Restore plugins/xatu for subsequent builds
[ "$QUIET" = false ] && echo "-> Restoring plugins/xatu for subsequent builds..."
mkdir -p plugins/xatu
cp "$SCRIPT_DIR/plugins/xatu/build.gradle" plugins/xatu/
cp -r "$SCRIPT_DIR/plugins/xatu/src" plugins/xatu/

if [ "$QUIET" = false ]; then
    echo ""
    echo "* Done!"
fi
