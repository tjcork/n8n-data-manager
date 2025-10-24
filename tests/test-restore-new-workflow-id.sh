#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR="${SCRIPT_DIR%/tests}"
MANAGER_SCRIPT="$ROOT_DIR/n8n-push.sh"
LICENSE_PATCH_SCRIPT="$SCRIPT_DIR/license-patch.js"

CONTAINER_NAME="n8n-restore-id-test"
TEST_EMAIL="restore-test@example.com"
TEST_PASSWORD="SuperSecret123!"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TEST_VERBOSE=${TEST_VERBOSE:-${VERBOSE_TESTS:-0}}

MSYS_PATH_ENV=()
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
  MSYS_PATH_ENV=(MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*')
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

docker_cmd() {
  env "${MSYS_PATH_ENV[@]}" docker "$@"
}

cleanup() {
  log_info "Cleaning up test environment..."
  docker_cmd rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
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
  log_error "Required license patch helper missing at $LICENSE_PATCH_SCRIPT"
  exit 1
fi

LICENSE_PATCH_MOUNT="$LICENSE_PATCH_SCRIPT"
if command -v cygpath >/dev/null 2>&1; then
  LICENSE_PATCH_MOUNT=$(cygpath -m "$LICENSE_PATCH_SCRIPT")
fi

log_info "Starting workflow ID sanitization restore test"
log_verbose_mode

log_info "Starting disposable n8n container ($CONTAINER_NAME) with license bypass"
docker_cmd run -d \
  --name "$CONTAINER_NAME" \
  -p 5679:5678 \
  -v "$LICENSE_PATCH_MOUNT:/license-patch.js:ro" \
  --user root \
  --entrypoint sh \
  n8nio/n8n:latest \
  -c 'node /license-patch.js && exec su node -c "/docker-entrypoint.sh start"' >/dev/null

log_info "Waiting for n8n to become ready"
if ! wait_for_n8n_ready "http://localhost:5679/" 180 3; then
  log_error "n8n did not become ready within timeout"
    exit 1
fi

log_info "Preparing fixture workflow directory"
TEMP_HOME=$(mktemp -d)
SESSION_COOKIES="$TEMP_HOME/session.cookies"
: >"$SESSION_COOKIES"
RESTORE_BASE="$TEMP_HOME/n8n-backup"
mkdir -p \
  "$RESTORE_BASE/Personal/Projects/Folder/Subfolder" \
  "$RESTORE_BASE/Personal/Project1" \
  "$RESTORE_BASE/Personal/Project2"

cat <<'JSON' >"$RESTORE_BASE/Personal/Projects/Folder/Subfolder/001_bad_id.json"
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

cat <<'JSON' >"$RESTORE_BASE/Personal/002_no_id.json"
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

cat <<'JSON' >"$RESTORE_BASE/Personal/Project1/003_correct.json"
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

cat <<'JSON' >"$RESTORE_BASE/Personal/Project2/004_duplicate.json"
{
  "id": "12345678abcdefgh",
  "name": "Duplicate ID Workflow",
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
  "$RESTORE_BASE"/Personal/Projects/Folder/Subfolder/001_bad_id.json \
  "$RESTORE_BASE"/Personal/002_no_id.json \
  "$RESTORE_BASE"/Personal/Project1/003_correct.json \
  "$RESTORE_BASE"/Personal/Project2/004_duplicate.json

log_info "Creating n8n session user"
docker_cmd exec -u node "$CONTAINER_NAME" \
  n8n user-management:reset \
    --email "$TEST_EMAIL" \
    --password "$TEST_PASSWORD" \
    --firstName Test \
    --lastName Restore >/dev/null

log_info "Completing owner setup via REST API"
sleep 2
if ! OWNER_SETUP_RESPONSE=$(curl -sSf \
  -c "$SESSION_COOKIES" \
  -b "$SESSION_COOKIES" \
   -H "Content-Type: application/json" \
  -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\",\"firstName\":\"Test\",\"lastName\":\"Restore\"}" \
  "http://localhost:5679/rest/owner/setup"); then
  log_error "Failed to establish n8n session owner via REST API"
    exit 1
fi

if ! jq -e --arg email "$TEST_EMAIL" '.data.email == $email' <<<"$OWNER_SETUP_RESPONSE" >/dev/null; then
  log_error "Unexpected response from owner setup endpoint"
    printf '%s\n' "$OWNER_SETUP_RESPONSE" >&2
    exit 1
fi

MANIFEST_PATH="$TEMP_HOME/manifest.json"
RESTORE_LOG="$TEMP_HOME/restore.log"

log_info "Running restore with sanitized workflow IDs"
CLI_VERBOSE_FLAGS=()
if [[ "$TEST_VERBOSE" != "0" ]]; then
  CLI_VERBOSE_FLAGS+=(--verbose)
fi

RESTORE_BASE_URL="http://localhost:5679"
RESTORE_PATH_CONVERTED=$(convert_path_for_cli "$RESTORE_BASE")

manager_env=(
  "DOCKER_EXEC_USER=node"
  "HOME=$TEMP_HOME"
  "RESTORE_MANIFEST_DEBUG_PATH=$MANIFEST_PATH"
)

if [[ ${#MSYS_PATH_ENV[@]} -gt 0 ]]; then
  manager_env+=("${MSYS_PATH_ENV[@]}")
fi

if ! env "${manager_env[@]}" \
  "$MANAGER_SCRIPT" \
    --action restore \
    --container "$CONTAINER_NAME" \
    --local-path "$RESTORE_PATH_CONVERTED" \
    --workflows 1 \
    --credentials 0 \
    --folder-structure \
    --n8n-url "$RESTORE_BASE_URL" \
  --n8n-email "$TEST_EMAIL" \
  --n8n-password "$TEST_PASSWORD" \
    --github-path "Personal/" \
    --defaults \
    "${CLI_VERBOSE_FLAGS[@]}" \
    2>&1 | tee "$RESTORE_LOG"; then
  while IFS= read -r line; do
    log_error "$line"
  done <"$RESTORE_LOG"
  exit 1
fi

if ! grep -q "Successfully authenticated with n8n session" "$RESTORE_LOG"; then
  log_error "Expected session-based authentication to succeed"
  cat "$RESTORE_LOG" >&2
    exit 1
fi

if grep -q "Collecting folder entry without workflow ID" "$RESTORE_LOG"; then
  log_error "Folder collection should not miss workflow IDs"
  cat "$RESTORE_LOG" >&2
    exit 1
fi

log_info "Exporting workflows from n8n for verification"
docker_cmd exec -u node "$CONTAINER_NAME" sh -c 'n8n export:workflow --all --output=/tmp/export.json' >/dev/null

POST_EXPORT=$(docker_cmd exec -u node "$CONTAINER_NAME" sh -c 'cat /tmp/export.json')

WORKFLOW_COUNT=$(printf '%s' "$POST_EXPORT" | jq 'length')
if [[ "$WORKFLOW_COUNT" -ne 4 ]]; then
  log_error "Expected four workflows after restore, found $WORKFLOW_COUNT"
    exit 1
fi

INVALID_IDS=$(printf '%s' "$POST_EXPORT" | jq '[ .[].id | select(test("^[A-Za-z0-9]{16}$") | not) ] | length')
if [[ "$INVALID_IDS" -ne 0 ]]; then
    log_error "One or more restored workflows have invalid IDs"
    exit 1
fi

if [[ ! -f "$MANIFEST_PATH" ]]; then
    log_error "Expected reconciled manifest at $MANIFEST_PATH"
    exit 1
fi

MANIFEST_COUNT=$(jq -s 'length' "$MANIFEST_PATH")
if [[ "$MANIFEST_COUNT" -ne 4 ]]; then
  log_error "Expected manifest to contain four entries, found $MANIFEST_COUNT"
    cat "$MANIFEST_PATH" >&2
    exit 1
fi

MISSING_NOTES=$(jq -s '[ .[]
  | select((.originalWorkflowId // "") | length > 0)
  | select(((.originalWorkflowId // "") | test("^[A-Za-z0-9]{16}$")) | not)
  | select(((.sanitizedIdNote // "") | length) == 0)
] | length' "$MANIFEST_PATH")
if [[ "$MISSING_NOTES" -ne 0 ]]; then
  log_error "Manifest entries are missing sanitized ID notes"
  cat "$MANIFEST_PATH" >&2
  exit 1
fi

MANIFEST_MISMATCH=$(jq -s --argjson exported "$POST_EXPORT" '
  [ .[] as $entry |
    ($exported | map(select((.name // "") == ($entry.name // ""))) | first) as $match
    | if $match == null then {name: $entry.name, reason: "missing"}
      elif ($match.id // "") | test("^[A-Za-z0-9]{16}$") | not then {name: $entry.name, reason: "invalid_id"}
      else empty end
  ]
' "$MANIFEST_PATH")

if [[ "$MANIFEST_MISMATCH" != "[]" ]]; then
  log_error "Manifest did not align with exported workflow IDs"
  printf '%s\n' "$MANIFEST_MISMATCH" >&2
  cat "$MANIFEST_PATH" >&2
  exit 1
fi

SANITIZED_IDS=$(printf '%s' "$POST_EXPORT" | jq -r 'map({name: .name, id: .id})')
log_info "Verified sanitized workflow IDs: $SANITIZED_IDS"

log_info "Authenticating REST session for folder verification"
sleep 2

LOGIN_METADATA=$(curl -sS --retry 5 --retry-delay 2 --retry-all-errors -c "$SESSION_COOKIES" -b "$SESSION_COOKIES" \
  -H "X-Requested-With: XMLHttpRequest" \
  -H "Accept: application/json" \
  "http://localhost:5679/rest/login")

CSRF_TOKEN=$(jq -r '.data.csrfToken // empty' <<<"$LOGIN_METADATA" || true)

if [[ -z "$CSRF_TOKEN" || "$CSRF_TOKEN" == "null" ]]; then
  if ! jq -e '.data.email? // empty' <<<"$LOGIN_METADATA" >/dev/null; then
    log_error "Failed to obtain CSRF token for login"
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
    log_error "Failed to establish authenticated session for folder verification"
    printf '%s\n' "$LOGIN_RESPONSE" >&2
    exit 1
  fi
fi

PROJECTS_JSON_PATH="$TEMP_HOME/projects.json"
FOLDERS_JSON_PATH="$TEMP_HOME/folders.json"
WORKFLOWS_JSON_PATH="$TEMP_HOME/workflows-api.json"

curl -sS --retry 5 --retry-delay 2 --retry-all-errors -f -b "$SESSION_COOKIES" "http://localhost:5679/rest/projects?skip=0&take=250" >"$PROJECTS_JSON_PATH"
if [[ ! -s "$PROJECTS_JSON_PATH" ]]; then
  log_error "Failed to fetch projects for folder verification"
  exit 1
fi

PROJECT_ID=$(jq -r '.data[]? | select((.type // "") == "personal") | .id' "$PROJECTS_JSON_PATH" | head -n1)
if [[ -z "$PROJECT_ID" ]]; then
  log_error "Unable to determine personal project identifier from projects payload"
  cat "$PROJECTS_JSON_PATH" >&2
  exit 1
fi

curl -sS --retry 5 --retry-delay 2 --retry-all-errors -f -b "$SESSION_COOKIES" "http://localhost:5679/rest/projects/$PROJECT_ID/folders?skip=0&take=1000" >"$FOLDERS_JSON_PATH"
if [[ ! -s "$FOLDERS_JSON_PATH" ]]; then
  log_error "Failed to fetch folders for project $PROJECT_ID"
  exit 1
fi

curl -sS --retry 5 --retry-delay 2 --retry-all-errors -f -b "$SESSION_COOKIES" "http://localhost:5679/rest/workflows?includeScopes=true&includeFolders=true&filter=%7B%22isArchived%22%3Afalse%7D&skip=0&take=2000&sortBy=updatedAt%3Adesc" >"$WORKFLOWS_JSON_PATH"
if [[ ! -s "$WORKFLOWS_JSON_PATH" ]]; then
  log_error "Failed to fetch workflows with folder metadata"
  exit 1
fi

EXPECTED_FOLDERS_PATH="$TEMP_HOME/expected-folders.json"
cat <<'JSON' >"$EXPECTED_FOLDERS_PATH"
[
  {"name":"Bad ID Workflow","path":["Projects","Folder","Subfolder"]},
  {"name":"No ID Workflow","path":[]},
  {"name":"Correct ID Workflow","path":["Project1"]},
  {"name":"Duplicate ID Workflow","path":["Project2"]}
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
    (if (($projectName // "") | ascii_downcase) == "personal" then
       if (($fullPath | length) > 0) and (($fullPath[0] // "" | ascii_downcase) == "personal") then
         $fullPath[1:]
       else
         $fullPath
       end
     else
       $fullPath
     end) as $normalizedFullPath |
    if ($normalizedFullPath == $exp.path) then empty else {name: $exp.name, status: "path_mismatch", actual: $normalizedFullPath, expected: $exp.path} end
      end
    ]
  ')

if [[ "$FOLDER_VERIFICATION" != "[]" ]]; then
  log_error "Folder placement verification failed: $FOLDER_VERIFICATION"
  exit 1
fi

log_success "Verified workflow folder placements."
log_success "Test completed successfully"
