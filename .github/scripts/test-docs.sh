#!/bin/bash
set -e

SCRIPT_FILE='n8n-manager.sh'
README_FILE='readme.md'

echo "Validating README.md structure..."
required_sections=("Features" "Prerequisites" "Installation" "Configuration" "Usage")

for section in "${required_sections[@]}"; do
  if grep -q "## .*$section" $README_FILE; then
    echo "✅ Found: $section"
  else
    echo "❌ Missing: $section"
    exit 1
  fi
done

echo "Checking help text consistency..."
./$SCRIPT_FILE --help > script-help.txt

if grep -q "Usage:" $README_FILE; then
  echo "✅ README contains usage information"
else
  echo "❌ README missing usage information"
  exit 1
fi

echo "Checking version consistency..."
SCRIPT_VERSION=$(grep -E '^SCRIPT_VERSION=' $SCRIPT_FILE | cut -d'"' -f2)

if grep -q "$SCRIPT_VERSION" $README_FILE; then
  echo "✅ Version consistent: $SCRIPT_VERSION"
else
  echo "❌ Version mismatch in README"
  echo "Script version: $SCRIPT_VERSION"
  echo "README version references:"
  grep -n "version\|Version" $README_FILE || echo "None found"
  exit 1
fi
