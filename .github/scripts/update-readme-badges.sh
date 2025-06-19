#!/bin/bash
set -Eeuo pipefail
set -x # Enable command tracing for debugging
IFS=$'\n\t'

README_FILE="readme.md"
SCRIPT_FILE="n8n-manager.sh"

# Function to update a badge in README.md
# Arguments: <badge_name_placeholder> <badge_url_markdown>
update_badge() {
    local placeholder="$1"
    local markdown="$2"
    if grep -q "<!-- $placeholder -->" "$README_FILE"; then
        awk -v placeholder="$placeholder" -v md="$markdown" '
        BEGIN {p_start = "<!-- " placeholder " -->"; p_end = "<!-- " placeholder "_END -->"}
        $0 ~ p_start {print; print md; in_block=1; next}
        $0 ~ p_end {print; in_block=0; next}
        !in_block {print}
        ' "$README_FILE" > tmp_readme.md && mv tmp_readme.md "$README_FILE"
        echo "Updated badge: $placeholder"
    else
        echo "Warning: Placeholder '$placeholder' not found in $README_FILE. Badge not updated."
    fi
}

# --- Configuration & Dynamic Data --- 
# Attempt to get version from script file
SCRIPT_VERSION=""
script_version_line=$(grep -E '^SCRIPT_VERSION=' "$SCRIPT_FILE" || true)
if [ -n "$script_version_line" ]; then
    SCRIPT_VERSION=$(echo "$script_version_line" | cut -d'"' -f2)
elif version_line=$(grep -E '^VERSION=' "$SCRIPT_FILE" || true); [ -n "$version_line" ]; then
    SCRIPT_VERSION=$(echo "$version_line" | cut -d'"' -f2)
fi

if [ -z "${SCRIPT_VERSION}" ]; then
    echo "Error: Could not extract SCRIPT_VERSION or VERSION from $SCRIPT_FILE. Version badge will be skipped." >&2
    # Decide if this is fatal or if we proceed without version
fi

# GitHub repository details (owner/repo)
# Assumes the remote 'origin' is a GitHub URL like https://github.com/OWNER/REPO.git or git@github.com:OWNER/REPO.git
ORIGIN_URL=$(git config --get remote.origin.url || echo "")
if [[ "$ORIGIN_URL" =~ github.com[/:]([^/]+)/([^/.]+)(\.git)?$ ]]; then
    OWNER_NAME="${BASH_REMATCH[1]}"
    REPO_NAME="${BASH_REMATCH[2]}"
else
    echo "Error: Could not parse OWNER_NAME and REPO_NAME from git remote origin URL: $ORIGIN_URL" >&2
    echo "Skipping GitHub-dependent badges."
    OWNER_NAME="your-owner"
    REPO_NAME="your-repo" # Fallback values
fi

GITHUB_REPO_SLUG="$OWNER_NAME/$REPO_NAME"
CI_WORKFLOW_FILE="ci.yml" # Assuming your CI workflow file is named ci.yml
MAIN_BRANCH_NAME=$(git rev-parse --abbrev-ref HEAD || echo "main") # Get current branch, fallback to main
LICENSE_TYPE="MIT" # Default, can be made dynamic if LICENSE file is parsable

# --- Badge Markdown Generation --- 
# Style parameter for Shields.io (e.g., flat, flat-square, plastic, social)
BADGE_STYLE="flat-square"

# 1. Build Status (GitHub Actions)
BUILD_STATUS_BADGE="[![Build Status](https://img.shields.io/github/actions/workflow/status/$GITHUB_REPO_SLUG/$CI_WORKFLOW_FILE?branch=$MAIN_BRANCH_NAME&style=$BADGE_STYLE)](https://github.com/$GITHUB_REPO_SLUG/actions/workflows/$CI_WORKFLOW_FILE)"

# 2. Latest Release Version
# Uses GitHub's latest release badge (can be 'latest' or 'latest-pre')
LATEST_RELEASE_BADGE=""
if [ -n "$SCRIPT_VERSION" ]; then # Only add if version was found
    LATEST_RELEASE_BADGE="[![Latest Release](https://img.shields.io/github/v/release/$GITHUB_REPO_SLUG?include_prereleases&style=$BADGE_STYLE&label=release)](https://github.com/$GITHUB_REPO_SLUG/releases/latest)"
    # Or, if using the SCRIPT_VERSION directly:
    # LATEST_RELEASE_BADGE="[![Release Version](https://img.shields.io/badge/release-v$SCRIPT_VERSION-$([ "$SCRIPT_VERSION" == "" ] && echo "lightgrey" || echo "blue")&style=$BADGE_STYLE)](https://github.com/$GITHUB_REPO_SLUG/releases/tag/v$SCRIPT_VERSION)"
fi

# 3. License
LICENSE_BADGE="[![License: $LICENSE_TYPE](https://img.shields.io/badge/License-$LICENSE_TYPE-yellow.svg?style=$BADGE_STYLE)](LICENSE)"

# 4. Last Commit (to main/default branch)
LAST_COMMIT_BADGE="[![Last Commit](https://img.shields.io/github/last-commit/$GITHUB_REPO_SLUG/$MAIN_BRANCH_NAME?style=$BADGE_STYLE)](https://github.com/$GITHUB_REPO_SLUG/commits/$MAIN_BRANCH_NAME)"

# 5. GitHub Stars
STARS_BADGE="[![GitHub Stars](https://img.shields.io/github/stars/$GITHUB_REPO_SLUG?style=$BADGE_STYLE&logo=github)](https://github.com/$GITHUB_REPO_SLUG/stargazers)"

# 6. GitHub Forks
FORKS_BADGE="[![GitHub Forks](https://img.shields.io/github/forks/$GITHUB_REPO_SLUG?style=$BADGE_STYLE&logo=github)](https://github.com/$GITHUB_REPO_SLUG/network/members)"

# 7. Open Issues
OPEN_ISSUES_BADGE="[![Open Issues](https://img.shields.io/github/issues-raw/$GITHUB_REPO_SLUG?style=$BADGE_STYLE&logo=github)](https://github.com/$GITHUB_REPO_SLUG/issues)"

# 8. Contributors
CONTRIBUTORS_BADGE="[![Contributors](https://img.shields.io/github/contributors/$GITHUB_REPO_SLUG?style=$BADGE_STYLE)](https://github.com/$GITHUB_REPO_SLUG/graphs/contributors)"

# 9. ShellCheck (Manual link, or could be from CI artifact if CI generates a badge URL)
# This assumes your CI workflow is named 'ci.yml' and has a job named 'shellcheck'
# The URL points to the latest run of the workflow on the main branch.
SHELLCHECK_BADGE="[![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen?style=$BADGE_STYLE)](https://github.com/$GITHUB_REPO_SLUG/actions/workflows/$CI_WORKFLOW_FILE?query=branch%3A$MAIN_BRANCH_NAME)" # Placeholder, update if CI provides a specific badge

# 10. Code Size
CODE_SIZE_BADGE="[![Repo Size](https://img.shields.io/github/repo-size/$GITHUB_REPO_SLUG?style=$BADGE_STYLE)](https://github.com/$GITHUB_REPO_SLUG)"

# 11. Project Status (Static)
PROJECT_STATUS_BADGE="[![Project Status: Active](https://img.shields.io/badge/status-active-success.svg?style=$BADGE_STYLE)](./#)"

# --- Update README.md --- 
update_badge "BADGE_BUILD_STATUS" "$BUILD_STATUS_BADGE"
if [ -n "$LATEST_RELEASE_BADGE" ]; then update_badge "BADGE_LATEST_RELEASE" "$LATEST_RELEASE_BADGE"; fi
update_badge "BADGE_LICENSE" "$LICENSE_BADGE"
update_badge "BADGE_LAST_COMMIT" "$LAST_COMMIT_BADGE"
update_badge "BADGE_STARS" "$STARS_BADGE"
update_badge "BADGE_FORKS" "$FORKS_BADGE"
update_badge "BADGE_OPEN_ISSUES" "$OPEN_ISSUES_BADGE"
update_badge "BADGE_CONTRIBUTORS" "$CONTRIBUTORS_BADGE"
update_badge "BADGE_SHELLCHECK" "$SHELLCHECK_BADGE"
update_badge "BADGE_CODE_SIZE" "$CODE_SIZE_BADGE"
update_badge "BADGE_PROJECT_STATUS" "$PROJECT_STATUS_BADGE"

echo "README badges update process completed."
exit 0
