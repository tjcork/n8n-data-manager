#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR="${SCRIPT_DIR%/tests}"
MANAGER_SCRIPT="$ROOT_DIR/n8n-manager.sh"

CONTAINER_NAME="n8n-restore-id-test"
TEST_EMAIL="restore-test@example.com"
TEST_PASSWORD="SuperSecret123!"

cleanup() {
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    if [[ -n "${TEMP_HOME:-}" && -d "$TEMP_HOME" ]]; then
        rm -rf "$TEMP_HOME"
    fi
}
trap cleanup EXIT

log() {
    printf '[test] %s\n' "$*"
}

log "Starting disposable n8n container ($CONTAINER_NAME)"
docker run -d \
  --name "$CONTAINER_NAME" \
  -p 5679:5678 \
  n8nio/n8n:latest >/dev/null

log "Waiting for n8n to become ready"
sleep 35

log "Preparing fixture workflow directory"
TEMP_HOME=$(mktemp -d)
RESTORE_BASE="$TEMP_HOME/n8n-backup"
mkdir -p \
  "$RESTORE_BASE/Personal/Projects/Acme/Inbound" \
  "$RESTORE_BASE/Personal/Projects/Acme/Outbound" \
  "$RESTORE_BASE/Personal/Inbox"

cat <<'JSON' >"$RESTORE_BASE/Personal/Projects/Acme/Inbound/001_trigger.json"
{
  "id": "wf-1",
  "name": "Inbound Sync Flow",
  "nodes": [
    {
      "parameters": {},
      "name": "Start",
      "type": "n8n-nodes-base.start",
      "typeVersion": 1,
      "position": [240, 240]
    }
  ],
  "meta": {
    "instanceId": "test-instance-1"
  },
  "connections": {}
}
JSON

cat <<'JSON' >"$RESTORE_BASE/Personal/Projects/Acme/Outbound/002_notifier.json"
{
  "id": "wf-2",
  "name": "Outbound Notifier",
  "nodes": [
    {
      "parameters": {},
      "name": "When Webhook Calls",
      "type": "n8n-nodes-base.webhook",
      "typeVersion": 1,
      "position": [240, 240]
    }
  ],
  "meta": {
    "instanceId": "test-instance-2"
  },
  "connections": {}
}
JSON

cat <<'JSON' >"$RESTORE_BASE/Personal/Inbox/003_cleanup.json"
{
  "id": "wf-3",
  "name": "Inbox Cleanup",
  "nodes": [
    {
      "parameters": {},
      "name": "Cron",
      "type": "n8n-nodes-base.cron",
      "typeVersion": 1,
      "position": [240, 240]
    }
  ],
  "meta": {
    "instanceId": "test-instance-3"
  },
  "connections": {}
}
JSON

chmod 600 \
  "$RESTORE_BASE"/Personal/Projects/Acme/Inbound/001_trigger.json \
  "$RESTORE_BASE"/Personal/Projects/Acme/Outbound/002_notifier.json \
  "$RESTORE_BASE"/Personal/Inbox/003_cleanup.json

log "Creating n8n session user"
docker exec -u node "$CONTAINER_NAME" \
  n8n user-management:reset \
    --email "$TEST_EMAIL" \
    --password "$TEST_PASSWORD" \
    --firstName Test \
    --lastName Restore >/dev/null

log "Completing owner setup via REST API"
sleep 2
if ! OWNER_SETUP_RESPONSE=$(curl -sSf \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\",\"firstName\":\"Test\",\"lastName\":\"Restore\"}" \
  "http://localhost:5679/rest/owner/setup"); then
    echo "Failed to establish n8n session owner via REST API" >&2
    exit 1
fi

if ! jq -e --arg email "$TEST_EMAIL" '.data.email == $email' <<<"$OWNER_SETUP_RESPONSE" >/dev/null; then
    echo "Unexpected response from owner setup endpoint" >&2
    printf '%s\n' "$OWNER_SETUP_RESPONSE" >&2
    exit 1
fi

cat <<CFG >"$TEMP_HOME/test-config.cfg"
ASSUME_DEFAULTS=true
FOLDER_STRUCTURE=true
WORKFLOWS=1
CREDENTIALS=0
N8N_BASE_URL="http://localhost:5679"
N8N_EMAIL="$TEST_EMAIL"
N8N_PASSWORD="$TEST_PASSWORD"
N8N_LOGIN_CREDENTIAL_NAME="session-login"
GITHUB_PATH_PREFIX="/"
CFG

MANIFEST_PATH="$TEMP_HOME/manifest.json"
RESTORE_LOG="$TEMP_HOME/restore.log"

log "Running restore with sanitized workflow IDs"
if ! HOME="$TEMP_HOME" \
    RESTORE_MANIFEST_DEBUG_PATH="$MANIFEST_PATH" \
    "$MANAGER_SCRIPT" \
        --action restore \
        --container "$CONTAINER_NAME" \
        --path "$RESTORE_BASE" \
        --workflows 1 \
        --credentials 0 \
        --duplicate-strategy replace \
        --config "$TEMP_HOME/test-config.cfg" \
        --defaults \
        --verbose 2>&1 | tee "$RESTORE_LOG"; then
    cat "$RESTORE_LOG" >&2
    exit 1
fi

if ! grep -q "Successfully authenticated with n8n session" "$RESTORE_LOG"; then
    echo "Expected session-based authentication to succeed" >&2
    cat "$RESTORE_LOG" >&2
    exit 1
fi

if grep -q "Collecting folder entry without workflow ID" "$RESTORE_LOG"; then
    echo "Folder collection should not miss workflow IDs" >&2
    cat "$RESTORE_LOG" >&2
    exit 1
fi

log "Exporting workflows from n8n for verification"
docker exec "$CONTAINER_NAME" sh -c 'n8n export:workflow --all --output=/tmp/export.json' >/dev/null

POST_EXPORT=$(docker exec "$CONTAINER_NAME" sh -c 'cat /tmp/export.json')

WORKFLOW_COUNT=$(printf '%s' "$POST_EXPORT" | jq 'length')
if [[ "$WORKFLOW_COUNT" -ne 3 ]]; then
    echo "Expected three workflows after restore, found $WORKFLOW_COUNT" >&2
    exit 1
fi

INVALID_IDS=$(printf '%s' "$POST_EXPORT" | jq '[ .[].id | select(test("^[A-Za-z0-9]{16}$") | not) ] | length')
if [[ "$INVALID_IDS" -ne 0 ]]; then
    echo "One or more restored workflows have invalid IDs" >&2
    exit 1
fi

if [[ ! -f "$MANIFEST_PATH" ]]; then
    echo "Expected reconciled manifest at $MANIFEST_PATH" >&2
    exit 1
fi

MANIFEST_COUNT=$(jq 'length' "$MANIFEST_PATH")
if [[ "$MANIFEST_COUNT" -ne 3 ]]; then
    echo "Expected manifest to contain three entries, found $MANIFEST_COUNT" >&2
    cat "$MANIFEST_PATH" >&2
    exit 1
fi

MISSING_NOTES=$(jq '[ .[] | select(((.sanitizedIdNote // "") | length) == 0) ] | length' "$MANIFEST_PATH")
if [[ "$MISSING_NOTES" -ne 0 ]]; then
  echo "Manifest entries are missing sanitized ID notes" >&2
  cat "$MANIFEST_PATH" >&2
  exit 1
fi

MANIFEST_MISMATCH=$(jq -n --argjson manifest "$(cat "$MANIFEST_PATH")" --argjson exported "$POST_EXPORT" '
  [ $manifest[] as $entry |
  ($exported | map(select((.name // "") == ($entry.name // ""))) | first) as $match
  | if $match == null then {name: $entry.name, reason: "missing"}
    elif ($match.id // "") | test("^[A-Za-z0-9]{16}$") | not then {name: $entry.name, reason: "invalid_id"}
    else empty end
  ]
')

if [[ "$MANIFEST_MISMATCH" != "[]" ]]; then
  echo "Manifest did not align with exported workflow IDs" >&2
  printf '%s\n' "$MANIFEST_MISMATCH" >&2
  cat "$MANIFEST_PATH" >&2
  exit 1
fi

SANITIZED_IDS=$(printf '%s' "$POST_EXPORT" | jq -r 'map({name: .name, id: .id})')
log "Verified sanitized workflow IDs: $SANITIZED_IDS"

log "Test completed successfully"
