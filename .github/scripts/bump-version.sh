#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

# Script to bump version in n8n-manager.sh and create a version commit

SCRIPT_FILE="n8n-manager.sh"

# Function to get current version
get_current_version() {
    grep -E '^SCRIPT_VERSION=' "$SCRIPT_FILE" | cut -d'"' -f2
}

# Function to bump version (major, minor, patch)
# Expects one argument: major, minor, or patch
bump_version_component() {
    local current_version=$1
    local component=$2
    local major minor patch

    major=$(echo "$current_version" | cut -d. -f1)
    minor=$(echo "$current_version" | cut -d. -f2)
    patch=$(echo "$current_version" | cut -d. -f3)

    case "$component" in
        major) major=$((major + 1)); minor=0; patch=0 ;;
        minor) minor=$((minor + 1)); patch=0 ;;
        patch) patch=$((patch + 1)) ;;
        *) echo "Error: Invalid version component '$component' specified."; exit 1 ;;
    esac
    echo "$major.$minor.$patch"
}

# Determine version bump based on commit messages (simplified placeholder)
# In a real scenario, this would involve analyzing commit messages (e.g., conventional commits)
# For now, we'll default to 'patch' or take it from an environment variable
BUMP_TYPE="${VERSION_BUMP_TYPE:-patch}" # Default to patch, can be overridden by env var

CURRENT_VERSION=$(get_current_version)
NEW_VERSION=$(bump_version_component "$CURRENT_VERSION" "$BUMP_TYPE")

echo "Current version: $CURRENT_VERSION"
echo "Bumping type: $BUMP_TYPE"
echo "New version: $NEW_VERSION"

# Update version in script file
sed -i "s/^SCRIPT_VERSION=.*/SCRIPT_VERSION=\"$NEW_VERSION\"/" "$SCRIPT_FILE"

# Output new version for GitHub Actions
echo "new_version=$NEW_VERSION" >> "$GITHUB_OUTPUT"

# Create a commit for the version bump
# This part will be handled by the GitHub workflow using the new version

exit 0
