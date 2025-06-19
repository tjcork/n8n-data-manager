#!/bin/bash
set -e

SCRIPT_FILE='n8n-manager.sh'
INSTALL_FILE='install.sh'

echo "# Security Scan Results" > security-report.md
echo "" >> security-report.md

echo "## Potential Security Issues" >> security-report.md

echo "### Command Injection Risks" >> security-report.md
grep -n 'eval\|exec\|[`]' $SCRIPT_FILE $INSTALL_FILE >> security-report.md || echo "None found" >> security-report.md

echo "" >> security-report.md
echo "### Unsafe Variable Usage" >> security-report.md
grep -n '\$[a-zA-Z_][a-zA-Z0-9_]*[^"]' $SCRIPT_FILE $INSTALL_FILE | head -20 >> security-report.md || echo "None found" >> security-report.md

echo "" >> security-report.md
echo "### Hardcoded Secrets Check" >> security-report.md
grep -i -n "password\|secret\|key\|token" $SCRIPT_FILE $INSTALL_FILE | grep -v "GITHUB_TOKEN\|CONF_" >> security-report.md || echo "None found" >> security-report.md
