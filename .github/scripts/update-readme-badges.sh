#!/bin/bash
set -Eeuo pipefail
set -x # Enable command tracing for debugging
IFS=$'\n\t'

README_FILE="readme.md"
SCRIPT_FILE="n8n-manager.sh"

# Function to update a badge in README.md
# Arguments: <badge_name_placeholder> <badge_url>
update_badge() {
    local placeholder="$1"
    local url="$2"
    # Ensure the placeholder exists before attempting to replace
    if grep -q "<!-- $placeholder -->" "$README_FILE"; then
        # Using awk for more robust replacement across lines if needed
        awk -v placeholder="$placeholder" -v url="$url" '
        BEGIN {p_start = "<!-- " placeholder " -->"; p_end = "<!-- " placeholder "_END -->"}
        $0 ~ p_start {print; print url; in_block=1; next}
        $0 ~ p_end {print; in_block=0; next}
        !in_block {print}
        ' "$README_FILE" > tmp_readme.md && mv tmp_readme.md "$README_FILE"
        echo "Updated badge: $placeholder"
    else
        echo "Warning: Placeholder '$placeholder' not found in $README_FILE."
    fi
}

# Get script version
# Try to get SCRIPT_VERSION
script_version_line=$(grep -E '^SCRIPT_VERSION=' "$SCRIPT_FILE" || true) # Allow grep to fail without exiting script
if [ -n "$script_version_line" ]; then
    SCRIPT_VERSION=$(echo "$script_version_line" | cut -d'"' -f2)
else
    # Fallback to checking for VERSION if SCRIPT_VERSION was not found
    version_line=$(grep -E '^VERSION=' "$SCRIPT_FILE" || true) # Allow grep to fail without exiting script
    if [ -n "$version_line" ]; then
        SCRIPT_VERSION=$(echo "$version_line" | cut -d'"' -f2)
    fi
fi

# Check if SCRIPT_VERSION was successfully extracted
if [ -z "${SCRIPT_VERSION:-}" ]; then # Use :- to handle unbound variable if set -u is also active
    echo "Error: Could not extract SCRIPT_VERSION or VERSION from $SCRIPT_FILE" >&2
    exit 1
fi

# Get other dynamic info (placeholders for now, can be expanded)
REPO_NAME="$(basename -s .git "$(git config --get remote.origin.url)")"
OWNER_NAME="$(git config --get remote.origin.url | sed -n 's|.*github.com/\([^/]*\)/.*|\1|p')"
LAST_COMMIT_DATE_FORMATTED=$(date -u +"%Y-%m-%d") # Simplified, actual last commit date is better
LICENSE_TYPE="MIT" # Assuming MIT, can be made dynamic

# Generate badge URLs (examples)
VERSION_BADGE_URL="[![Version](https://img.shields.io/badge/version-$SCRIPT_VERSION-blue.svg)](https://github.com/$OWNER_NAME/$REPO_NAME/releases/tag/v$SCRIPT_VERSION)"
LICENSE_BADGE_URL="[![License](https://img.shields.io/badge/license-$LICENSE_TYPE-green.svg)](LICENSE)"
LAST_COMMIT_BADGE_URL="[![Last Commit](https://img.shields.io/badge/last%20commit-$LAST_COMMIT_DATE_FORMATTED-orange.svg)](https://github.com/$OWNER_NAME/$REPO_NAME/commits/main)"
# Add more badges as needed (e.g., open issues, stars, build status from ci.yml)
# BUILD_STATUS_BADGE_URL="[![Build Status](https://github.com/$OWNER_NAME/$REPO_NAME/actions/workflows/ci.yml/badge.svg)](https://github.com/$OWNER_NAME/$REPO_NAME/actions/workflows/ci.yml)"

# Update badges in README
update_badge "BADGE_VERSION" "$VERSION_BADGE_URL"
update_badge "BADGE_LICENSE" "$LICENSE_BADGE_URL"
update_badge "BADGE_LAST_COMMIT" "$LAST_COMMIT_BADGE_URL"
# update_badge "BADGE_BUILD_STATUS" "$BUILD_STATUS_BADGE_URL"

echo "README badges update process completed."

# The workflow will handle committing this file.

exit 0
