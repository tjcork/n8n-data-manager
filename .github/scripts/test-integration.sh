#!/bin/bash
set -Eeuo pipefail # Stricter error handling
IFS=$'\n\t'

INSTALL_FILE_BASENAME='install.sh'
REPORT_NAME='integration-report.md'
# If GITHUB_WORKSPACE is not set (e.g., when running locally), default to current directory
if [ -z "${GITHUB_WORKSPACE:-}" ]; then
  GITHUB_WORKSPACE="$PWD"
fi
REPORT_PATH="$GITHUB_WORKSPACE/$REPORT_NAME" # Create report directly in workspace

TEST_DIR=""

cleanup() {
  echo "Running cleanup..."
  if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then
    echo "Removing temporary directory: $TEST_DIR"
    rm -rf "$TEST_DIR"
  fi
}
trap cleanup EXIT SIGINT SIGTERM

echo "Integration Test Script Started. Report will be at: $REPORT_PATH"

# Initialize report early
echo "# Integration Test Results (In Progress)" > "$REPORT_PATH"

if [ ! -f "$GITHUB_WORKSPACE/$INSTALL_FILE_BASENAME" ]; then
    echo "ERROR: Install script $GITHUB_WORKSPACE/$INSTALL_FILE_BASENAME not found!" >> "$REPORT_PATH"
    exit 1
fi
# The CI workflow step should make install.sh executable. This is a fallback.
# chmod +x "$GITHUB_WORKSPACE/$INSTALL_FILE_BASENAME" || { echo "ERROR: Failed to chmod +x $INSTALL_FILE_BASENAME" >> "$REPORT_PATH"; exit 1; }

TEST_DIR=$(mktemp -d)
if [ -z "$TEST_DIR" ] || [ ! -d "$TEST_DIR" ]; then
    echo "ERROR: Failed to create temporary directory with mktemp." >> "$REPORT_PATH"
    exit 1
fi
echo "Temporary directory created: $TEST_DIR" >> "$REPORT_PATH"

cp "$GITHUB_WORKSPACE/$INSTALL_FILE_BASENAME" "$TEST_DIR/test-install.sh" || { echo "ERROR: Failed to copy install script to $TEST_DIR" >> "$REPORT_PATH"; exit 1; }

pushd "$TEST_DIR" > /dev/null || { echo "ERROR: Failed to cd into $TEST_DIR" >> "$REPORT_PATH"; exit 1; }

echo "Modifying ./test-install.sh (changing install path to ./local-bin, removing sudo)" >> "$REPORT_PATH"
sed -i 's|/usr/local/bin|./local-bin|g' ./test-install.sh || { echo "ERROR: sed for install path failed" >> "$REPORT_PATH"; popd > /dev/null; exit 1; }
sed -i 's|sudo ||g' ./test-install.sh || { echo "ERROR: sed for sudo removal failed" >> "$REPORT_PATH"; popd > /dev/null; exit 1; }

mkdir -p ./local-bin || { echo "ERROR: Failed to create ./local-bin directory" >> "$REPORT_PATH"; popd > /dev/null; exit 1; }

echo "Running modified ./test-install.sh..." # This goes to stdout, not report yet
INSTALL_OUTPUT_FILE="install_output.txt"
INSTALL_ERROR_FILE="install_error.txt"

bash ./test-install.sh > "$INSTALL_OUTPUT_FILE" 2> "$INSTALL_ERROR_FILE"
INSTALL_EXIT_CODE=$?

popd > /dev/null # Return from TEST_DIR

# Finalize Report Content (overwrite initial progress message)
echo "# Integration Test Results" > "$REPORT_PATH"
echo "" >> "$REPORT_PATH"
echo "- Test environment: Ubuntu Latest (GitHub Actions Runner)" >> "$REPORT_PATH"
echo "- Temporary test directory used: $TEST_DIR (now cleaned up)" >> "$REPORT_PATH"
echo "- Installation script ($INSTALL_FILE_BASENAME) execution exit code: $INSTALL_EXIT_CODE" >> "$REPORT_PATH"
echo "" >> "$REPORT_PATH"

echo "## Installation Script Output (stdout from $TEST_DIR/$INSTALL_OUTPUT_FILE):" >> "$REPORT_PATH"
cat "$TEST_DIR/$INSTALL_OUTPUT_FILE" >> "$REPORT_PATH"
echo "" >> "$REPORT_PATH"

if [ -s "$TEST_DIR/$INSTALL_ERROR_FILE" ]; then
    echo "## Installation Script Errors (stderr from $TEST_DIR/$INSTALL_ERROR_FILE):" >> "$REPORT_PATH"
    cat "$TEST_DIR/$INSTALL_ERROR_FILE" >> "$REPORT_PATH"
    echo "" >> "$REPORT_PATH"
fi

# System info - make robust
DOCKER_VERSION=$(docker --version 2>/dev/null || echo "Docker not found or error during version check")
GIT_VERSION=$(git --version 2>/dev/null || echo "Git not found or error during version check")
CURL_VERSION=$(curl --version 2>/dev/null | head -1 || echo "Curl not found or error during version check")
BASH_VERSION=$(bash --version 2>/dev/null | head -1 || echo "Bash not found or error during version check")

echo "## System Information from Runner" >> "$REPORT_PATH"
echo "- Docker available: $DOCKER_VERSION" >> "$REPORT_PATH"
echo "- Git available: $GIT_VERSION" >> "$REPORT_PATH"
echo "- Curl available: $CURL_VERSION" >> "$REPORT_PATH"
echo "- Bash available: $BASH_VERSION" >> "$REPORT_PATH"

echo "Integration test script finished. Report generated at $REPORT_PATH"

exit $INSTALL_EXIT_CODE
