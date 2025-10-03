#!/bin/bash
set -e

SCRIPT_FILE='n8n-manager.sh'
INSTALL_FILE='install.sh'

echo "Validating syntax of $SCRIPT_FILE..."
bash -n $SCRIPT_FILE

echo "Validating syntax of $INSTALL_FILE..."
bash -n $INSTALL_FILE

echo "Testing script execution with --help flag..."
chmod +x $SCRIPT_FILE
./$SCRIPT_FILE --help || true

echo "Testing script execution with --dry-run flag..."
./$SCRIPT_FILE --action backup --dry-run --verbose --defaults || true

echo "Testing script execution with --dry-run flag..."
./$SCRIPT_FILE --action restore --dry-run --verbose --defaults || true