#!/bin/bash
set -e

SCRIPT_FILE='n8n-manager.sh'
INSTALL_FILE='install.sh'

echo "Running ShellCheck on $SCRIPT_FILE..."
shellcheck -f gcc -e SC1091 -e SC2034 -e SC2154 $SCRIPT_FILE

echo "Running ShellCheck on $INSTALL_FILE..."
shellcheck -f gcc -e SC1091 $INSTALL_FILE

echo "# ShellCheck Results" > shellcheck-report.md
echo "" >> shellcheck-report.md
echo "## Main Script ($SCRIPT_FILE)" >> shellcheck-report.md
shellcheck -f diff $SCRIPT_FILE >> shellcheck-report.md 2>&1 || true
echo "" >> shellcheck-report.md
echo "## Install Script ($INSTALL_FILE)" >> shellcheck-report.md
shellcheck -f diff $INSTALL_FILE >> shellcheck-report.md 2>&1 || true
