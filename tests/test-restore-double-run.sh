#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR="${SCRIPT_DIR%/tests}"
MANAGER_SCRIPT="$ROOT_DIR/n8n-push.sh"
LICENSE_PATCH_SCRIPT="$SCRIPT_DIR/license-patch.js"

CONTAINER_NAME="n8n-restore-double-run"
CONTAINER_PORT=5681
TEST_EMAIL="double-restore@example.com"
TEST_PASSWORD="SuperSecret123!"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TEST_VERBOSE=${TEST_VERBOSE:-${VERBOSE_TESTS:-0}}

if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
  export MSYS_NO_PATHCONV=1
  export MSYS2_ARG_CONV_EXCL='*'
fi

log_info() {
  printf '%b[TEST]%b %s\n' "$YELLOW" "$NC" "$*"
}

log_success() {
  printf '%b[PASS]%b %s\n' "$GREEN" "$NC" "$*"
}

log_error() {
  printf '%b[FAIL]%b %s\n' "$RED" "$NC" "$*"
}

should_keep_artifacts() {
  if [[ -n "${KEEP_TEST_ARTIFACTS:-}" ]]; then
    return 0
  fi
  if [[ -n "${SAVE_TEST_OUTPUTS:-}" ]]; then
    return 0
  fi
  if [[ "${SAVE_TEST_ARTIFACTS:-0}" != "0" ]]; then
    return 0
  fi
  return 1
}

log_verbose_mode() {
  if [[ "$TEST_VERBOSE" != "0" ]]; then
    log_info "Running n8n-push.sh in verbose mode"
  fi
}

convert_path_for_cli() {
  local input_path="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$input_path"
  else
    printf '%s\n' "$input_path"
  fi
}

cleanup() {
  log_info "Cleaning up test environment..."
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  if [[ -n "${TEMP_HOME:-}" && -d "$TEMP_HOME" ]]; then
    if should_keep_artifacts; then
      log_info "Preserving temporary test artifacts in $TEMP_HOME"
    else
      rm -rf "$TEMP_HOME"
    fi
  fi
}
trap cleanup EXIT

wait_for_n8n_ready() {
  local url="$1"
  local timeout_seconds="${2:-180}"
  local interval_seconds="${3:-3}"
  local elapsed=0

  while (( elapsed < timeout_seconds )); do
    if curl -s --connect-timeout 2 --max-time 5 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$interval_seconds"
    elapsed=$((elapsed + interval_seconds))
  done

  return 1
}

if [[ ! -f "$LICENSE_PATCH_SCRIPT" ]]; then
  log_error "Required license patch helper missing at $LICENSE_PATCH_SCRIPT"
  exit 1
fi

LICENSE_PATCH_MOUNT="$LICENSE_PATCH_SCRIPT"
if command -v cygpath >/dev/null 2>&1; then
  LICENSE_PATCH_MOUNT=$(cygpath -m "$LICENSE_PATCH_SCRIPT")
fi

log_info "Starting double restore integration test"
log_verbose_mode

log_info "Starting disposable n8n container ($CONTAINER_NAME) with license bypass"
docker run -d \
  --name "$CONTAINER_NAME" \
  -p ${CONTAINER_PORT}:5678 \
  -v "$LICENSE_PATCH_MOUNT:/license-patch.js:ro" \
  --user root \
  --entrypoint sh \
  n8nio/n8n:latest \
  -c 'node /license-patch.js && exec su node -c "/docker-entrypoint.sh start"' >/dev/null

log_info "Waiting for n8n to become ready"
if ! wait_for_n8n_ready "http://localhost:${CONTAINER_PORT}/" 240 3; then
  log_error "n8n did not become ready within timeout"
  exit 1
fi

log_info "Creating owner credentials for API access"
docker exec -u node "$CONTAINER_NAME" \
  n8n user-management:reset \
    --email "$TEST_EMAIL" \
    --password "$TEST_PASSWORD" \
    --firstName Restore \
    --lastName Double >/dev/null

sleep 2
OWNER_SETUP_RESPONSE=$(curl -sSf \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\",\"firstName\":\"Restore\",\"lastName\":\"Double\"}" \
  "http://localhost:${CONTAINER_PORT}/rest/owner/setup")

if ! jq -e --arg email "$TEST_EMAIL" '.data.email == $email' <<<"$OWNER_SETUP_RESPONSE" >/dev/null; then
  log_error "Failed to initialize n8n owner account"
  printf '%s\n' "$OWNER_SETUP_RESPONSE" >&2
  exit 1
fi

TEMP_HOME=$(mktemp -d)
BACKUP_ROOT="$TEMP_HOME/n8n-backup"
RESTORE_MANIFEST_FIRST="$TEMP_HOME/manifest-first.json"
RESTORE_MANIFEST_SECOND="$TEMP_HOME/manifest-second.json"
RESTORE_LOG_FIRST="$TEMP_HOME/restore-first.log"
RESTORE_LOG_SECOND="$TEMP_HOME/restore-second.log"

mkdir -p "$BACKUP_ROOT"

sync_fixture_to_backup() {
  local source_dir="$1"
  if [[ -z "$source_dir" || ! -d "$source_dir" ]]; then
    log_error "Fixture directory not found: $source_dir"
    exit 1
  fi

  rm -rf "$BACKUP_ROOT"
  mkdir -p "$BACKUP_ROOT"

  # Ensure directories are created before copying for consistent permissions
  find "$source_dir" -type d -print0 | while IFS= read -r -d '' dir_path; do
    local rel_path
    rel_path=${dir_path#"$source_dir"}
    mkdir -p "$BACKUP_ROOT/$rel_path"
    chmod 700 "$dir_path"
  done

  find "$source_dir" -type f -print0 | while IFS= read -r -d '' file_path; do
    local rel_path
    rel_path=${file_path#"$source_dir/"}
    local target_path="$BACKUP_ROOT/$rel_path"
    mkdir -p "$(dirname "$target_path")"
    cp "$file_path" "$target_path"
    chmod 600 "$file_path"
    chmod 600 "$target_path"
  done
}

TARGET_FOLDER_REL="Personal/Clients/Acme"
FIRST_RESTORE_DIR="$TEMP_HOME/restore-first"
SECOND_RESTORE_DIR="$TEMP_HOME/restore-second"
mkdir -p "$FIRST_RESTORE_DIR/$TARGET_FOLDER_REL"

log_info "Generating first restore fixture"
cat <<'JSON' >"$FIRST_RESTORE_DIR/$TARGET_FOLDER_REL/alpha.json"
{
  "name": "Folder Workflow Alpha",
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
    "instanceId": "double-restore-alpha"
  },
  "connections": {}
}
JSON

cat <<'JSON' >"$FIRST_RESTORE_DIR/$TARGET_FOLDER_REL/beta.json"
{
  "name": "Folder Workflow Beta",
  "nodes": [
    {
      "parameters": {},
      "name": "Interval",
      "type": "n8n-nodes-base.interval",
      "typeVersion": 1,
      "position": [240, 240]
    }
  ],
  "meta": {
    "instanceId": "double-restore-beta"
  },
  "connections": {}
}
JSON

chmod 600 "$FIRST_RESTORE_DIR/$TARGET_FOLDER_REL"/*.json

log_info "Staging first fixture into backup directory"
sync_fixture_to_backup "$FIRST_RESTORE_DIR"

RESTORE_BASE_URL="http://localhost:${CONTAINER_PORT}"
CLI_VERBOSE_FLAGS=()
if [[ "$TEST_VERBOSE" != "0" ]]; then
  CLI_VERBOSE_FLAGS+=(--verbose)
fi

log_info "Running initial structured restore"
RESTORE_SOURCE_PATH=$(convert_path_for_cli "$FIRST_RESTORE_DIR")
if ! DOCKER_EXEC_USER="node" \
  HOME="$TEMP_HOME" \
  RESTORE_MANIFEST_DEBUG_PATH="$RESTORE_MANIFEST_FIRST" \
  "$MANAGER_SCRIPT" \
    --action restore \
    --container "$CONTAINER_NAME" \
    --local-path "$RESTORE_SOURCE_PATH" \
    --workflows 1 \
    --credentials 0 \
    --github-path "" \
    --folder-structure \
    --n8n-url "$RESTORE_BASE_URL" \
  --n8n-email "$TEST_EMAIL" \
  --n8n-password "$TEST_PASSWORD" \
    --defaults \
    "${CLI_VERBOSE_FLAGS[@]}" \
    2>&1 | tee "$RESTORE_LOG_FIRST"; then
  while IFS= read -r line; do
    log_error "$line"
  done <"$RESTORE_LOG_FIRST"
  exit 1
fi

log_info "Exporting workflows after first restore"
docker exec -u node "$CONTAINER_NAME" sh -c 'n8n export:workflow --all --output=/tmp/export-first.json' >/dev/null
FIRST_EXPORT=$(docker exec -u node "$CONTAINER_NAME" sh -c 'cat /tmp/export-first.json')

ID_ALPHA_FIRST=$(printf '%s' "$FIRST_EXPORT" | jq -r '.[] | select(.name == "Folder Workflow Alpha") | .id' || true)
ID_BETA_FIRST=$(printf '%s' "$FIRST_EXPORT" | jq -r '.[] | select(.name == "Folder Workflow Beta") | .id' || true)

if [[ -z "$ID_ALPHA_FIRST" || -z "$ID_BETA_FIRST" ]]; then
  log_error "Failed to locate restored workflow IDs after first run"
  printf '%s\n' "$FIRST_EXPORT" >&2
  exit 1
fi

for workflow_id in "$ID_ALPHA_FIRST" "$ID_BETA_FIRST"; do
  if ! [[ "$workflow_id" =~ ^[A-Za-z0-9]{16}$ ]]; then
    log_error "Unexpected workflow ID format: $workflow_id"
    exit 1
  fi
done

mkdir -p "$SECOND_RESTORE_DIR/$TARGET_FOLDER_REL"
log_info "Preparing second restore fixture with intentional ID mismatches"
cat <<'JSON' >"$SECOND_RESTORE_DIR/$TARGET_FOLDER_REL/alpha.json"
{
  "id": "AAAAAAAAAAAAAAAA",
  "name": "Folder Workflow Alpha",
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
    "instanceId": "double-restore-alpha"
  },
  "connections": {}
}
JSON

cat <<'JSON' >"$SECOND_RESTORE_DIR/$TARGET_FOLDER_REL/beta.json"
{
  "id": "BBBBBBBBBBBBBBBB",
  "name": "Folder Workflow Beta",
  "nodes": [
    {
      "parameters": {},
      "name": "Interval",
      "type": "n8n-nodes-base.interval",
      "typeVersion": 1,
      "position": [240, 240]
    }
  ],
  "meta": {
    "instanceId": "double-restore-beta"
  },
  "connections": {}
}
JSON

cat <<JSON >"$SECOND_RESTORE_DIR/$TARGET_FOLDER_REL/gamma.json"
{
  "id": "$ID_ALPHA_FIRST",
  "name": "Folder Workflow Gamma",
  "nodes": [
    {
      "parameters": {},
      "name": "Webhook",
      "type": "n8n-nodes-base.webhook",
      "typeVersion": 1,
      "position": [240, 240]
    }
  ],
  "meta": {
    "instanceId": "double-restore-gamma"
  },
  "connections": {}
}
JSON

chmod 600 "$SECOND_RESTORE_DIR/$TARGET_FOLDER_REL"/*.json

log_info "Staging second fixture into backup directory"
sync_fixture_to_backup "$SECOND_RESTORE_DIR"

log_info "Running second structured restore"
RESTORE_SOURCE_PATH=$(convert_path_for_cli "$SECOND_RESTORE_DIR")
if ! DOCKER_EXEC_USER="node" \
  HOME="$TEMP_HOME" \
  RESTORE_MANIFEST_DEBUG_PATH="$RESTORE_MANIFEST_SECOND" \
  "$MANAGER_SCRIPT" \
    --action restore \
    --container "$CONTAINER_NAME" \
    --local-path "$RESTORE_SOURCE_PATH" \
    --workflows 1 \
    --credentials 0 \
    --github-path "" \
    --folder-structure \
    --n8n-url "$RESTORE_BASE_URL" \
  --n8n-email "$TEST_EMAIL" \
  --n8n-password "$TEST_PASSWORD" \
    --defaults \
    "${CLI_VERBOSE_FLAGS[@]}" \
    2>&1 | tee "$RESTORE_LOG_SECOND"; then
  while IFS= read -r line; do
    log_error "$line"
  done <"$RESTORE_LOG_SECOND"
  exit 1
fi

log_info "Exporting workflows after second restore"
docker exec -u node "$CONTAINER_NAME" sh -c 'n8n export:workflow --all --output=/tmp/export-second.json' >/dev/null
SECOND_EXPORT=$(docker exec -u node "$CONTAINER_NAME" sh -c 'cat /tmp/export-second.json')

ID_ALPHA_SECOND=$(printf '%s' "$SECOND_EXPORT" | jq -r '.[] | select(.name == "Folder Workflow Alpha") | .id' || true)
ID_BETA_SECOND=$(printf '%s' "$SECOND_EXPORT" | jq -r '.[] | select(.name == "Folder Workflow Beta") | .id' || true)
ID_GAMMA_SECOND=$(printf '%s' "$SECOND_EXPORT" | jq -r '.[] | select(.name == "Folder Workflow Gamma") | .id' || true)

if [[ -z "$ID_ALPHA_SECOND" || -z "$ID_BETA_SECOND" || -z "$ID_GAMMA_SECOND" ]]; then
  log_error "Expected workflows missing after second restore"
  printf '%s\n' "$SECOND_EXPORT" >&2
  exit 1
fi

if [[ "$ID_ALPHA_SECOND" != "$ID_ALPHA_FIRST" ]]; then
  log_error "Alpha workflow ID changed across restores ($ID_ALPHA_FIRST -> $ID_ALPHA_SECOND)"
  exit 1
fi

if [[ "$ID_BETA_SECOND" != "$ID_BETA_FIRST" ]]; then
  log_error "Beta workflow ID changed across restores ($ID_BETA_FIRST -> $ID_BETA_SECOND)"
  exit 1
fi

if [[ "$ID_GAMMA_SECOND" == "$ID_ALPHA_FIRST" ]]; then
  log_error "Gamma workflow incorrectly reused an unrelated ID"
  exit 1
fi

if ! [[ "$ID_GAMMA_SECOND" =~ ^[A-Za-z0-9]{16}$ ]]; then
  log_error "Gamma workflow received invalid ID format: $ID_GAMMA_SECOND"
  exit 1
fi

for workflow_name in "Folder Workflow Alpha" "Folder Workflow Beta" "Folder Workflow Gamma"; do
  local_count=$(printf '%s' "$SECOND_EXPORT" | jq --arg name "$workflow_name" '[ .[] | select(.name == $name) ] | length')
  if [[ "$local_count" -ne 1 ]]; then
    log_error "Unexpected workflow count for $workflow_name after second restore"
    printf '%s\n' "$SECOND_EXPORT" >&2
    exit 1
  fi
done

log_success "Double restore verification succeeded"
