#!/bin/bash
# OpenClaw Sentinel Release Script
# Bumps version, creates tag, and pushes to trigger release workflow
# Usage: ./scripts/release.sh [patch|minor|major]

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$REPO_DIR/VERSION"

info()    { echo -e "${GREEN}$*${NC}"; }
warn()    { echo -e "${YELLOW}$*${NC}"; }
error()   { echo -e "${RED}$*${NC}" >&2; }

usage() {
    echo "Usage: $0 [patch|minor|major]"
    echo ""
    echo "Bumps the version, creates a git tag, and pushes to trigger a GitHub Release."
    echo ""
    echo "  patch  - Bump patch version (1.0.0 -> 1.0.1)"
    echo "  minor  - Bump minor version (1.0.0 -> 1.1.0)"
    echo "  major  - Bump major version (1.0.0 -> 2.0.0)"
    exit 1
}

# Validate arguments
BUMP_TYPE="${1:-}"
if [ -z "$BUMP_TYPE" ]; then
    usage
fi

case "$BUMP_TYPE" in
    patch|minor|major) ;;
    *) error "Invalid bump type: $BUMP_TYPE"; usage ;;
esac

# Ensure we're in a git repo
if ! git -C "$REPO_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
    error "Error: Not a git repository"
    exit 1
fi

# Ensure working tree is clean
if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
    error "Error: Working tree is not clean. Commit or stash changes first."
    exit 1
fi

# Read current version
if [ ! -f "$VERSION_FILE" ]; then
    error "Error: VERSION file not found at $VERSION_FILE"
    exit 1
fi

CURRENT_VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')

# Parse semver
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

if [ -z "$MAJOR" ] || [ -z "$MINOR" ] || [ -z "$PATCH" ]; then
    error "Error: Invalid version format in VERSION file: $CURRENT_VERSION"
    exit 1
fi

# Bump version
case "$BUMP_TYPE" in
    patch) PATCH=$((PATCH + 1)) ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
esac

NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
TAG="v${NEW_VERSION}"

# Check if tag already exists
if git -C "$REPO_DIR" tag -l "$TAG" | grep -q "$TAG"; then
    error "Error: Tag $TAG already exists"
    exit 1
fi

echo ""
info "Releasing OpenClaw Sentinel"
echo "  Current version: $CURRENT_VERSION"
echo "  New version:     $NEW_VERSION ($BUMP_TYPE bump)"
echo "  Tag:             $TAG"
echo ""

read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# Update VERSION file
echo "$NEW_VERSION" > "$VERSION_FILE"
info "✓ Updated VERSION to $NEW_VERSION"

# Commit and tag
git -C "$REPO_DIR" add VERSION
git -C "$REPO_DIR" commit -m "release: v${NEW_VERSION}"
info "✓ Created release commit"

git -C "$REPO_DIR" tag -a "$TAG" -m "Release $TAG"
info "✓ Created tag $TAG"

# Push
git -C "$REPO_DIR" push origin main
git -C "$REPO_DIR" push origin "$TAG"
info "✓ Pushed to origin"

echo ""
info "Release $TAG pushed! GitHub Actions will create the release."
echo "  Track progress: https://github.com/clawdbrunner/openclaw-sentinel/actions"
