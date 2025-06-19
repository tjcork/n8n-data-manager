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
echo 'CONF_VERBOSE=true' > ~/.config/n8n-manager/config
./$SCRIPT_FILE --action backup --container test-n8n --dry-run || true
