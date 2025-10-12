#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR="${SCRIPT_DIR%/tests}"
MANAGER_SCRIPT="$ROOT_DIR/n8n-manager.sh"
LICENSE_PATCH_SCRIPT="$SCRIPT_DIR/license-patch.js"

CONTAINER_NAME="n8n-restore-id-test"
TEST_EMAIL="restore-test@example.com"
TEST_PASSWORD="SuperSecret123!"

cleanup() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  if [[ -n "${TEMP_HOME:-}" && -d "$TEMP_HOME" ]]; then
    if [[ -n "${KEEP_TEST_ARTIFACTS:-}" ]]; then
      log "Preserving temporary test artifacts in $TEMP_HOME"
    else
      rm -rf "$TEMP_HOME"
    fi
  fi
}
trap cleanup EXIT

log() {
    printf '[test] %s\n' "$*"
}

wait_for_n8n_ready() {
  local url="$1"
  local timeout_seconds="${2:-120}"
  local interval_seconds="${3:-2}"
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
  echo "Required license patch helper missing at $LICENSE_PATCH_SCRIPT" >&2
  exit 1
fi

LICENSE_PATCH_MOUNT="$LICENSE_PATCH_SCRIPT"
if command -v cygpath >/dev/null 2>&1; then
  LICENSE_PATCH_MOUNT=$(cygpath -m "$LICENSE_PATCH_SCRIPT")
fi

log "Starting disposable n8n container ($CONTAINER_NAME) with license bypass"
docker run -d \
  --name "$CONTAINER_NAME" \
  -p 5679:5678 \
  -v "$LICENSE_PATCH_MOUNT:/license-patch.js:ro" \
  --user root \
  --entrypoint sh \
  n8nio/n8n:latest \
  -c 'node /license-patch.js && exec su node -c "/docker-entrypoint.sh start"' >/dev/null

log "Waiting for n8n to become ready"
if ! wait_for_n8n_ready "http://localhost:5679/" 180 3; then
    log "n8n did not become ready within timeout"
    exit 1
fi

log "Preparing fixture workflow directory"
TEMP_HOME=$(mktemp -d)
SESSION_COOKIES="$TEMP_HOME/session.cookies"
: >"$SESSION_COOKIES"
RESTORE_BASE="$TEMP_HOME/n8n-backup"
mkdir -p \
  "$RESTORE_BASE/Personal/Projects/Acme/Inbound" \
  "$RESTORE_BASE/Personal/Projects/Acme/Outbound" \
  "$RESTORE_BASE/Personal/Inbox"

cat <<'JSON' >"$RESTORE_BASE/Personal/Projects/Acme/Inbound/001_trigger.json"
{
  "id": "wf-1",
  "name": "Bad ID Workflow",
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
  "name": "No ID Workflow",
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
  "id": "12345678abcdefgh",
  "name": "Correct ID Workflow",
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

cat <<'JSON' >"$RESTORE_BASE/Personal/Inbox/004_extra.json"
{
  "id": "87654321hgfedcba",
  "name": "Additional Inbox Workflow",
  "nodes": [
    {
      "parameters": {},
      "name": "Cron",
      "type": "n8n-nodes-base.cron",
      "typeVersion": 1,
      "position": [360, 160]
    }
  ],
  "meta": {
    "instanceId": "test-instance-4"
  },
  "connections": {}
}
JSON

chmod 600 \
  "$RESTORE_BASE"/Personal/Projects/Acme/Inbound/001_trigger.json \
  "$RESTORE_BASE"/Personal/Projects/Acme/Outbound/002_notifier.json \
  "$RESTORE_BASE"/Personal/Inbox/003_cleanup.json \
  "$RESTORE_BASE"/Personal/Inbox/004_extra.json

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
  -c "$SESSION_COOKIES" \
  -b "$SESSION_COOKIES" \
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
if ! DOCKER_EXEC_USER="node" \
  HOME="$TEMP_HOME" \
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
docker exec -u node "$CONTAINER_NAME" sh -c 'n8n export:workflow --all --output=/tmp/export.json' >/dev/null

POST_EXPORT=$(docker exec -u node "$CONTAINER_NAME" sh -c 'cat /tmp/export.json')

WORKFLOW_COUNT=$(printf '%s' "$POST_EXPORT" | jq 'length')
if [[ "$WORKFLOW_COUNT" -ne 4 ]]; then
  echo "Expected four workflows after restore, found $WORKFLOW_COUNT" >&2
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
if [[ "$MANIFEST_COUNT" -ne 4 ]]; then
  echo "Expected manifest to contain four entries, found $MANIFEST_COUNT" >&2
    cat "$MANIFEST_PATH" >&2
    exit 1
fi

MISSING_NOTES=$(jq '[ .[]
  | select((.originalWorkflowId // "") | length > 0)
  | select(((.originalWorkflowId // "") | test("^[A-Za-z0-9]{16}$")) | not)
  | select(((.sanitizedIdNote // "") | length) == 0)
] | length' "$MANIFEST_PATH")
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

log "Authenticating REST session for folder verification"
sleep 2

LOGIN_METADATA=$(curl -sS --retry 5 --retry-delay 2 --retry-all-errors -c "$SESSION_COOKIES" -b "$SESSION_COOKIES" \
  -H "X-Requested-With: XMLHttpRequest" \
  -H "Accept: application/json" \
  "http://localhost:5679/rest/login")

CSRF_TOKEN=$(jq -r '.data.csrfToken // empty' <<<"$LOGIN_METADATA" || true)

if [[ -z "$CSRF_TOKEN" || "$CSRF_TOKEN" == "null" ]]; then
  if ! jq -e '.data.email? // empty' <<<"$LOGIN_METADATA" >/dev/null; then
    echo "Failed to obtain CSRF token for login" >&2
    printf '%s\n' "$LOGIN_METADATA" >&2
    exit 1
  fi
  LOGIN_RESPONSE="$LOGIN_METADATA"
else
  LOGIN_RESPONSE=$(curl -sS --retry 5 --retry-delay 2 --retry-all-errors -f -c "$SESSION_COOKIES" \
    -b "$SESSION_COOKIES" \
    -H "Content-Type: application/json" \
    -H "Origin: http://localhost:5679" \
    -H "Referer: http://localhost:5679/login" \
    -H "X-Requested-With: XMLHttpRequest" \
    -H "X-N8N-CSRF-Token: $CSRF_TOKEN" \
    -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\",\"rememberMe\":true}" \
    "http://localhost:5679/rest/login")

  if ! jq -e '.data != null' <<<"$LOGIN_RESPONSE" >/dev/null; then
    echo "Failed to establish authenticated session for folder verification" >&2
    printf '%s\n' "$LOGIN_RESPONSE" >&2
    exit 1
  fi
fi

PROJECTS_JSON_PATH="$TEMP_HOME/projects.json"
FOLDERS_JSON_PATH="$TEMP_HOME/folders.json"
WORKFLOWS_JSON_PATH="$TEMP_HOME/workflows-api.json"

curl -sS --retry 5 --retry-delay 2 --retry-all-errors -f -b "$SESSION_COOKIES" "http://localhost:5679/rest/projects?skip=0&take=250" >"$PROJECTS_JSON_PATH"
if [[ ! -s "$PROJECTS_JSON_PATH" ]]; then
  echo "Failed to fetch projects for folder verification" >&2
  exit 1
fi

PROJECT_ID=$(jq -r '.data[]? | select((.type // "") == "personal") | .id' "$PROJECTS_JSON_PATH" | head -n1)
if [[ -z "$PROJECT_ID" ]]; then
  echo "Unable to determine personal project identifier from projects payload" >&2
  cat "$PROJECTS_JSON_PATH" >&2
  exit 1
fi

curl -sS --retry 5 --retry-delay 2 --retry-all-errors -f -b "$SESSION_COOKIES" "http://localhost:5679/rest/projects/$PROJECT_ID/folders?skip=0&take=1000" >"$FOLDERS_JSON_PATH"
if [[ ! -s "$FOLDERS_JSON_PATH" ]]; then
  echo "Failed to fetch folders for project $PROJECT_ID" >&2
  exit 1
fi

curl -sS --retry 5 --retry-delay 2 --retry-all-errors -f -b "$SESSION_COOKIES" "http://localhost:5679/rest/workflows?includeScopes=true&includeFolders=true&filter=%7B%22isArchived%22%3Afalse%7D&skip=0&take=2000&sortBy=updatedAt%3Adesc" >"$WORKFLOWS_JSON_PATH"
if [[ ! -s "$WORKFLOWS_JSON_PATH" ]]; then
  echo "Failed to fetch workflows with folder metadata" >&2
  exit 1
fi

EXPECTED_FOLDERS_PATH="$TEMP_HOME/expected-folders.json"
cat <<'JSON' >"$EXPECTED_FOLDERS_PATH"
[
  {"name":"Bad ID Workflow","path":["Personal","Projects","Acme","Inbound"]},
  {"name":"No ID Workflow","path":["Personal","Projects","Acme","Outbound"]},
  {"name":"Correct ID Workflow","path":["Personal","Inbox"]},
  {"name":"Additional Inbox Workflow","path":["Personal","Inbox"]}
]
JSON

FOLDER_VERIFICATION=$(jq -n \
  --slurpfile workflows "$WORKFLOWS_JSON_PATH" \
  --slurpfile folders "$FOLDERS_JSON_PATH" \
  --slurpfile expected "$EXPECTED_FOLDERS_PATH" '
    def items(x):
      if (x | type) == "array" then x else (x.data // []) end;

    def build_map(folders):
      reduce (items(folders))[]? as $item ({}; . + { ($item.id // empty): { name: ($item.name // ""), parent: ($item.parentFolderId // null) }});

    def path_from_folder($id; $map):
      if ($id == null) or ($id == "") then []
      else
        ($map[$id] // {name: null, parent: null}) as $node |
        if $node.name == null then [] else (path_from_folder($node.parent; $map) + [$node.name]) end
      end;

    def workflow_parent_id($wf):
      if ($wf.parentFolderId // "") != "" then $wf.parentFolderId
      elif ($wf.parentFolder.id // "") != "" then $wf.parentFolder.id
      elif ($wf.folderId // "") != "" then $wf.folderId
      else null end;

    def workflow_project_name($wf):
      if (($wf.homeProject.type // "") | ascii_downcase) == "personal" then "Personal"
      elif ($wf.homeProject.name // "") != "" then $wf.homeProject.name
      elif ($wf.project // "") != "" then $wf.project
      else "Personal" end;

    def lookup_workflow($name; $wfData):
      (items($wfData) | map(select((.resource // "") == "workflow" and (.name // "") == $name)) | first);

    ($workflows[0] // {}) as $wfData |
    ($folders[0] // {}) as $folderData |
    (build_map($folderData)) as $map |
  ($expected[0] // []) as $expectedList |
  [ $expectedList[] as $exp |
      (lookup_workflow($exp.name; $wfData)) as $wf |
      if $wf == null then {name: $exp.name, status: "missing"}
      else
        (workflow_parent_id($wf)) as $folderRef |
        (path_from_folder($folderRef; $map)) as $path |
        (workflow_project_name($wf)) as $projectName |
        (if ($projectName // "") == "" then $path
         elif (($path | length) > 0 and $path[0] == $projectName) then $path
         else [$projectName] + $path end) as $fullPath |
        if ($fullPath == $exp.path) then empty else {name: $exp.name, status: "path_mismatch", actual: $fullPath, expected: $exp.path} end
      end
    ]
  ')

if [[ "$FOLDER_VERIFICATION" != "[]" ]]; then
  echo "Folder placement verification failed: $FOLDER_VERIFICATION" >&2
  exit 1
fi

log "Verified workflow folder placements."

log "Test completed successfully"
