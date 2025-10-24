#!/bin/bash
set -Eeuo pipefail
IFS=$'\n\t'

README_FILE="README.md"
SCRIPT_FILE="n8n-push.sh"

# --- Configuration & Dynamic Data --- 
# Attempt to get version from script file
SCRIPT_VERSION=""
if grep -qE '^VERSION=' "$SCRIPT_FILE" 2>/dev/null; then
    SCRIPT_VERSION=$(grep -E '^VERSION=' "$SCRIPT_FILE" | head -1 | cut -d'"' -f2)
fi

# GitHub repository details (owner/repo)
ORIGIN_URL=$(git config --get remote.origin.url || echo "")
if [[ "$ORIGIN_URL" =~ github.com[/:]([^/]+)/([^/.]+)(\.git)?$ ]]; then
    OWNER_NAME="${BASH_REMATCH[1]}"
    REPO_NAME="${BASH_REMATCH[2]}"
else
    echo "Error: Could not parse repository from git remote: $ORIGIN_URL" >&2
    exit 1
fi

GITHUB_REPO_SLUG="$OWNER_NAME/$REPO_NAME"
BADGE_STYLE="flat-square"

# --- Simple Badge Set ---
LATEST_RELEASE_BADGE="[![Latest Release](https://img.shields.io/github/v/release/$GITHUB_REPO_SLUG?style=$BADGE_STYLE)](https://github.com/$GITHUB_REPO_SLUG/releases/latest)"
LICENSE_BADGE="[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=$BADGE_STYLE)](LICENSE)"
STARS_BADGE="[![GitHub Stars](https://img.shields.io/github/stars/$GITHUB_REPO_SLUG?style=$BADGE_STYLE&logo=github)](https://github.com/$GITHUB_REPO_SLUG/stargazers)"
FORKS_BADGE="[![GitHub Forks](https://img.shields.io/github/forks/$GITHUB_REPO_SLUG?style=$BADGE_STYLE&logo=github)](https://github.com/$GITHUB_REPO_SLUG/network/members)"
CONTRIBUTORS_BADGE="[![Contributors](https://img.shields.io/github/contributors/$GITHUB_REPO_SLUG?style=$BADGE_STYLE)](https://github.com/$GITHUB_REPO_SLUG/graphs/contributors)"
LAST_COMMIT_BADGE="[![Last Commit](https://img.shields.io/github/last-commit/$GITHUB_REPO_SLUG?style=$BADGE_STYLE)](https://github.com/$GITHUB_REPO_SLUG/commits/main)"
STATUS_BADGE="[![Status: Active](https://img.shields.io/badge/status-active-success.svg?style=$BADGE_STYLE)](./#)"

# Compose badge line
ALL_BADGES_MARKDOWN="${LATEST_RELEASE_BADGE} ${LICENSE_BADGE} ${STARS_BADGE} ${FORKS_BADGE} ${CONTRIBUTORS_BADGE} ${LAST_COMMIT_BADGE} ${STATUS_BADGE}"

# --- Update README ---
if [[ ! -f "$README_FILE" ]]; then
    echo "Error: README file not found: $README_FILE" >&2
    exit 1
fi

# Create temp file
TEMP_FILE=$(mktemp)

# Replace content between markers
awk -v badges="$ALL_BADGES_MARKDOWN" '
    /<!-- ALL_BADGES_START -->/ { print; print ""; print badges; print ""; in_section=1; next }
    /<!-- ALL_BADGES_END -->/ { in_section=0 }
    !in_section { print }
' "$README_FILE" > "$TEMP_FILE"

# Replace original file
mv "$TEMP_FILE" "$README_FILE"

echo "✓ Updated badges in $README_FILE"
echo "Badges: Latest Release | License: MIT | GitHub Stars | GitHub Forks | Contributors | Last Commit | Status: Active"
ALL_BADGES_MARKDOWN+="$SHELLCHECK_BADGE "
ALL_BADGES_MARKDOWN+="$LICENSE_BADGE\n"

# Line 2
ALL_BADGES_MARKDOWN+="$STARS_BADGE "
ALL_BADGES_MARKDOWN+="$FORKS_BADGE "
ALL_BADGES_MARKDOWN+="$CONTRIBUTORS_BADGE "
ALL_BADGES_MARKDOWN+="$OPEN_ISSUES_BADGE\n"

# Line 3
ALL_BADGES_MARKDOWN+="$LAST_COMMIT_BADGE "
ALL_BADGES_MARKDOWN+="$CODE_SIZE_BADGE "
ALL_BADGES_MARKDOWN+="$PROJECT_STATUS_BADGE\n"

# Line 4
ALL_BADGES_MARKDOWN+="$TOP_LANGUAGE_BADGE "
ALL_BADGES_MARKDOWN+="$MAINTENANCE_STATUS_BADGE "
# Add new badges here, for example:
# DOWNLOADS_BADGE="[![GitHub All Releases](https://img.shields.io/github/downloads/$GITHUB_REPO_SLUG/total?style=$BADGE_STYLE)](https://github.com/$GITHUB_REPO_SLUG/releases)"
# TOP_LANGUAGE_BADGE="[![GitHub Top Language](https://img.shields.io/github/languages/top/$GITHUB_REPO_SLUG?style=$BADGE_STYLE)](https://github.com/$GITHUB_REPO_SLUG)"
# ALL_BADGES_MARKDOWN+="$DOWNLOADS_BADGE "
# ALL_BADGES_MARKDOWN+="$TOP_LANGUAGE_BADGE\n"

# --- Update README.md with the consolidated badge block ---
PLACEHOLDER_TAG="ALL_BADGES"
if grep -q "<!-- ${PLACEHOLDER_TAG}_START -->" "$README_FILE"; then
    # Use awk to replace content between placeholder comments
    awk -v placeholder_start="<!-- ${PLACEHOLDER_TAG}_START -->" \
        -v placeholder_end="<!-- ${PLACEHOLDER_TAG}_END -->" \
        -v content="${ALL_BADGES_MARKDOWN}" '
    BEGIN {printing=1}
    $0 ~ placeholder_start {
        print;
        print content;
        printing=0;
        next;
    }
    $0 ~ placeholder_end {
        printing=1;
    }
    printing {print}
    ' "$README_FILE" > tmp_readme.md && mv tmp_readme.md "$README_FILE"
    echo "Successfully updated all badges in $README_FILE."
else
    echo "Error: Placeholder '<!-- ${PLACEHOLDER_TAG}_START -->' or '<!-- ${PLACEHOLDER_TAG}_END -->' not found in $README_FILE." >&2
    exit 1
fi

echo "README badges update process completed."
exit 0
