#!/bin/bash

set -e

# Default values
ORG=""
REPO=""
BRANCH=""
CI_MODE=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--repo)
            IFS='/' read -ra REPO_PARTS <<< "$2"
            if [ ${#REPO_PARTS[@]} -ne 2 ]; then
                echo "Error: Repository must be in format 'org/repo'"
                exit 1
            fi
            ORG="${REPO_PARTS[0]}"
            REPO="${REPO_PARTS[1]}"
            shift 2
            ;;
        -b|--branch)
            BRANCH="$2"
            shift 2
            ;;
        --ci)
            CI_MODE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 -r org/repo -b branch [--ci]"
            echo "  --ci: Run in CI mode (non-interactive, auto-clean, auto-update patches)"
            exit 1
            ;;
    esac
done

# Validate required arguments
if [ -z "$ORG" ] || [ -z "$REPO" ] || [ -z "$BRANCH" ]; then
    echo "Error: Missing required arguments"
    echo "Usage: $0 -r org/repo -b branch [--ci]"
    echo "Example: $0 -r consensys/teku -b master"
    echo "         $0 -r consensys/teku -b master --ci"
    exit 1
fi

echo "Testing with repository: $ORG/$REPO on branch: $BRANCH"

# Check if teku directory exists and handle it smartly
if [ -d "teku" ]; then
    echo "Found existing teku directory, checking..."
    cd teku

    # Check if it's a git repository
    if [ -d ".git" ]; then
        # Get current remote URL
        CURRENT_REMOTE=$(git config --get remote.origin.url || echo "")
        EXPECTED_REMOTE="https://github.com/$ORG/$REPO.git"

        # Check if the remote matches
        if [ "$CURRENT_REMOTE" != "$EXPECTED_REMOTE" ]; then
            echo "Remote mismatch: current=$CURRENT_REMOTE, expected=$EXPECTED_REMOTE"
            cd ..
            echo "Removing existing teku directory..."
            rm -rf teku
            echo "Cloning repository..."
            git clone --depth 1 --branch "$BRANCH" "https://github.com/$ORG/$REPO.git" teku
        else
            # Check current branch
            CURRENT_BRANCH=$(git branch --show-current)
            if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
                echo "Branch mismatch: current=$CURRENT_BRANCH, expected=$BRANCH"

                # Check if directory is dirty before switching
                if [ -d "plugins/xatu" ] || ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
                    echo "WARNING: Teku directory has changes:"
                    # Show plugins/xatu directory if it exists
                    if [ -d "plugins/xatu" ]; then
                        echo "  - plugins/xatu/ directory exists"
                    fi
                    # Show git status if there are changes
                    if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
                        git status --short | head -20
                        if [ $(git status --short | wc -l) -gt 20 ]; then
                            echo "  ... and more files"
                        fi
                    fi
                    echo ""
                    if [ "$CI_MODE" = true ]; then
                        echo "CI mode: Auto-cleaning teku directory..."
                        REPLY="y"
                    else
                        read -p "Clean teku directory before switching branches? (y/N) " -n 1 -r
                        echo ""
                    fi
                    if [[ $REPLY =~ ^[Yy]$ ]]; then
                        echo "Cleaning teku directory..."
                        rm -rf plugins/xatu
                        rm -f libxatu.so libxatu.h
                        git reset --hard
                        git clean -fd
                        echo "Clean complete."
                    else
                        echo "Cannot switch branches with uncommitted changes. Exiting."
                        cd ..
                        exit 1
                    fi
                fi

                echo "Switching to branch $BRANCH..."
                git fetch --depth 1 origin "$BRANCH":"$BRANCH"
                git checkout "$BRANCH"
            fi

            # Check if we're on the latest commit
            echo "Checking for updates..."
            git fetch --depth 1 origin "$BRANCH" || true

            # Check if the remote branch exists in our refs
            if git rev-parse --verify "origin/$BRANCH" >/dev/null 2>&1; then
                LOCAL=$(git rev-parse HEAD)
                REMOTE=$(git rev-parse "origin/$BRANCH")

                if [ "$LOCAL" != "$REMOTE" ]; then
                    echo "Local branch is behind remote, pulling latest changes..."
                    git pull --depth 1 origin "$BRANCH"
                else
                    echo "Already on latest commit"
                fi
            else
                echo "Remote branch not found in shallow clone, assuming up to date"
            fi

            cd ..
        fi
    else
        # Not a git repository
        cd ..
        echo "Directory exists but is not a git repository, removing..."
        rm -rf teku
        echo "Cloning repository..."
        git clone --depth 1 --branch "$BRANCH" "https://github.com/$ORG/$REPO.git" teku
    fi
else
    # No teku directory exists
    echo "Cloning repository..."
    git clone --depth 1 --branch "$BRANCH" "https://github.com/$ORG/$REPO.git" teku
fi

# Store the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if teku directory is dirty
echo "Checking teku directory status..."
cd teku
if [ -d "plugins/xatu" ] || ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    echo "WARNING: Teku directory has changes:"
    # Show plugins/xatu directory if it exists
    if [ -d "plugins/xatu" ]; then
        echo "  - plugins/xatu/ directory exists"
    fi
    # Show git status if there are changes
    if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
        git status --short | head -20
        if [ $(git status --short | wc -l) -gt 20 ]; then
            echo "  ... and more files"
        fi
    fi
    echo ""
    if [ "$CI_MODE" = true ]; then
        echo "CI mode: Auto-cleaning teku directory..."
        REPLY="y"
    else
        read -p "Clean teku directory before continuing? (y/N) " -n 1 -r
        echo ""
    fi
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Cleaning teku directory..."
        rm -rf plugins/xatu
        rm -f libxatu.so libxatu.h
        git reset --hard
        echo "Clean complete."
    else
        echo "Continuing without cleaning..."
    fi
fi
cd ..

# Apply the temu patch (patch file + plugins/xatu module)
echo "Applying temu patch..."
"$SCRIPT_DIR/apply-temu-patch.sh" "$ORG/$REPO" "$BRANCH" teku

# Build the project
echo "Building teku..."
cd teku
if ./gradlew installDist; then
    echo "Build completed successfully!"
    cd ..

    echo ""
    echo "Generating patch from build changes..."

    # Use save-patch.sh to generate the patch
    CI_FLAGS=""
    if [ "$CI_MODE" = true ]; then
        CI_FLAGS="--ci"
    fi

    # Run save-patch.sh and capture the result
    if [ "$CI_MODE" = true ]; then
        # In CI mode, use quiet output
        PATCH_OUTPUT=$("$SCRIPT_DIR/save-patch.sh" -r "$ORG/$REPO" -b "$BRANCH" $CI_FLAGS teku 2>&1)
        PATCH_EXIT_CODE=$?
    else
        # In interactive mode, show full output
        "$SCRIPT_DIR/save-patch.sh" -r "$ORG/$REPO" -b "$BRANCH" teku
        PATCH_EXIT_CODE=$?
    fi

    if [ $PATCH_EXIT_CODE -eq 0 ]; then
        if [ "$CI_MODE" = true ]; then
            echo "Patch saved: $PATCH_OUTPUT"
        fi
        echo ""
        echo "Build and patch generation completed successfully!"
    elif [ $PATCH_EXIT_CODE -eq 2 ]; then
        echo "No changes detected - patch unchanged"
    else
        echo "Warning: Failed to generate patch (exit code: $PATCH_EXIT_CODE)"
    fi
else
    echo "Build failed!"
    exit 1
fi
