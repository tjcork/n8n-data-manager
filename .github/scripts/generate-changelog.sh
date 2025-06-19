#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

# Script to generate changelog using conventional-changelog-cli

# Ensure conventional-changelog-cli is installed
if ! command -v conventional-changelog &> /dev/null
then
    echo "conventional-changelog-cli not found. Installing..."
    npm install -g conventional-changelog-cli conventional-changelog-conventionalcommits
fi

# Generate changelog
# The preset 'conventionalcommits' is a good default. Others can be specified.
# It will overwrite CHANGELOG.md by default.
conventional-changelog -p conventionalcommits -i CHANGELOG.md -s -r 0

echo "Changelog generated/updated successfully: CHANGELOG.md"

# The workflow will handle committing this file.

exit 0
