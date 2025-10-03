#!/bin/bash
set -e

SCRIPT_FILE='n8n-manager.sh'

echo "Creating test n8n container..."
docker run -d \
  --name test-n8n \
  -p 5678:5678 \
  -e N8N_BASIC_AUTH_ACTIVE=true \
  -e N8N_BASIC_AUTH_USER=admin \
  -e N8N_BASIC_AUTH_PASSWORD=password \
  n8nio/n8n:latest

sleep 30
docker ps

chmod +x $SCRIPT_FILE

echo "Testing container detection..."
./$SCRIPT_FILE --action backup --container test-n8n --dry-run --verbose || true

echo "Testing help functionality..."
./$SCRIPT_FILE --help

echo "Testing configuration file parsing..."
mkdir -p ~/.config/n8n-manager
echo 'VERBOSE=true' > ~/.config/n8n-manager/config
./$SCRIPT_FILE --action backup --container test-n8n --dry-run || true

echo "Preparing local artifacts for restore dry run..."
RESTORE_FIXTURE_DIR=$(mktemp -d)
cat <<'JSON' > "$RESTORE_FIXTURE_DIR/workflows.json"
[
  {
    "id": "1",
    "name": "Sample Workflow",
    "nodes": [],
    "connections": {}
  }
]
JSON

cat <<'JSON' > "$RESTORE_FIXTURE_DIR/credentials.json"
[
  {
    "id": "1",
    "name": "Sample Credentials",
    "type": "httpBasicAuth",
    "data": {}
  }
]
JSON

chmod 600 "$RESTORE_FIXTURE_DIR/"*.json

echo "Testing restore functionality (dry run)..."
./$SCRIPT_FILE --action restore --container test-n8n --workflows 1 --credentials 1 --path "$RESTORE_FIXTURE_DIR" --dry-run --verbose || true

rm -rf "$RESTORE_FIXTURE_DIR"
