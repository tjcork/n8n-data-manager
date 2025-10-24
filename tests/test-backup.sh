#!/usr/bin/env bash
# =========================================================
# n8n push - Backup & Restore Test Suite
# =========================================================
# Tests backup and restore functionality with a real n8n container

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_CONTAINER="n8n-push-test"
TEST_BACKUP_DIR=$(mktemp -d "$PROJECT_ROOT/.tmp-test-backup.XXXXXX")

# Prevent MSYS from rewriting Docker paths on Windows hosts.
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
    export MSYS_NO_PATHCONV=1
    export MSYS2_ARG_CONV_EXCL='*'
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

TEST_VERBOSE=${TEST_VERBOSE:-${VERBOSE_TESTS:-0}}

log_verbose_mode() {
    if [[ "$TEST_VERBOSE" != "0" ]]; then
        log_info "Running n8n-push.sh invocations with --verbose enabled"
    fi
}

log_info() {
    echo -e "${YELLOW}[TEST]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

convert_path_for_jq() {
    local input_path="$1"
    if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
        cygpath -m "$input_path"
    else
        printf '%s\n' "$input_path"
    fi
}

# Cleanup function
cleanup() {
    log_info "Cleaning up test environment..."
    docker stop "$TEST_CONTAINER" >/dev/null 2>&1 || true
    docker rm "$TEST_CONTAINER" >/dev/null 2>&1 || true
    if should_keep_artifacts; then
        log_info "Preserving test artifacts in $TEST_BACKUP_DIR"
    else
        rm -rf "$TEST_BACKUP_DIR"
    fi
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

# Trap cleanup on exit
trap cleanup EXIT

# Start test
log_info "Starting n8n push backup/restore test suite"
log_verbose_mode

# Clean any previous test artifacts
cleanup
mkdir -p "$TEST_BACKUP_DIR"

# 1. Start n8n test container
log_info "Starting n8n test container..."
if ! docker run -d \
    --name "$TEST_CONTAINER" \
    -p 5674:5678 \
    -e N8N_BASIC_AUTH_ACTIVE=false \
    n8nio/n8n:latest; then
    log_error "Failed to start n8n container"
    exit 1
fi

log_info "Waiting for n8n to be ready..."
CONTAINER_READY=0
for attempt in {1..30}; do
    if docker ps --filter "name=$TEST_CONTAINER" --filter "status=running" --format '{{.ID}}' | grep -q .; then
        CONTAINER_READY=1
        break
    fi
    sleep 2
done

if [[ $CONTAINER_READY -ne 1 ]]; then
    log_error "n8n container not running"
    exit 1
fi
log_info "n8n container is running"

# Wait for the HTTP interface to become responsive before running CLI commands.
log_info "Waiting for n8n HTTP endpoint..."
HTTP_READY=0
for attempt in {1..40}; do
    if curl -sf "http://localhost:5674/healthz" >/dev/null 2>&1; then
        HTTP_READY=1
        break
    fi
    sleep 3
done

if [[ $HTTP_READY -ne 1 ]]; then
    log_error "n8n HTTP endpoint not responding"
    exit 1
fi
log_info "n8n HTTP endpoint is responsive"

# 2. Create test workflow in container
log_info "Creating test workflow..."
TEST_WORKFLOW='{"name":"Test Backup Workflow","nodes":[{"parameters":{},"name":"Start","type":"n8n-nodes-base.start","typeVersion":1,"position":[250,300]}],"connections":{},"active":false,"settings":{}}'

TEMP_WORKFLOW=$(docker exec "$TEST_CONTAINER" mktemp -p /tmp)
docker exec "$TEST_CONTAINER" sh -c "cat <<'EOF' > $TEMP_WORKFLOW
$TEST_WORKFLOW
EOF"
docker exec "$TEST_CONTAINER" n8n import:workflow --input "$TEMP_WORKFLOW" || {
    log_error "Failed to import test workflow"
    exit 1
}
log_info "Test workflow created"

# 3. Create test credential in container
log_info "Creating test credential..."
TEST_CREDENTIAL='[
  {
    "id": "credential-123",
    "name": "Test Basic Credential",
    "type": "httpBasicAuth",
    "typeVersion": 1,
    "nodesAccess": [],
    "data": {
      "user": "test-user",
      "password": "test-password"
    }
  }
]'

TEMP_CREDENTIAL=$(docker exec "$TEST_CONTAINER" mktemp -p /tmp)
docker exec "$TEST_CONTAINER" sh -c "cat <<'EOF' > $TEMP_CREDENTIAL
$TEST_CREDENTIAL
EOF"
docker exec "$TEST_CONTAINER" n8n import:credentials --input "$TEMP_CREDENTIAL" --decrypted >/dev/null || {
    log_error "Failed to import test credential"
    exit 1
}
log_info "Test credential created"

# 4. Run encrypted backup via n8n-push.sh
ENCRYPTED_BACKUP_DIR="$TEST_BACKUP_DIR/local-encrypted"
mkdir -p "$ENCRYPTED_BACKUP_DIR"

ENCRYPTED_BACKUP_DIR_ARG=$(convert_path_for_jq "$ENCRYPTED_BACKUP_DIR")

log_info "Running encrypted backup through n8n-push.sh..."
ENCRYPTED_BACKUP_LOG="$TEST_BACKUP_DIR/backup_encrypted.log"
CLI_VERBOSE_FLAGS=()
if [[ "$TEST_VERBOSE" != "0" ]]; then
    CLI_VERBOSE_FLAGS+=(--verbose)
fi

if ! MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' bash "$PROJECT_ROOT/n8n-push.sh" \
    --action backup \
    --container "$TEST_CONTAINER" \
    --workflows 1 \
    --credentials 1 \
    --environment 0 \
    --local-path "$ENCRYPTED_BACKUP_DIR_ARG" \
    --config /dev/null \
    --defaults \
    "${CLI_VERBOSE_FLAGS[@]}" \
    >"$ENCRYPTED_BACKUP_LOG" 2>&1; then
    log_error "Encrypted backup run failed"
    log_error "See $ENCRYPTED_BACKUP_LOG for details"
    exit 1
fi
log_success "Encrypted backup completed"

ENCRYPTED_WORKFLOW_JSON="$ENCRYPTED_BACKUP_DIR/workflows.json"
ENCRYPTED_CREDENTIALS_JSON="$ENCRYPTED_BACKUP_DIR/credentials.json"

if [[ ! -s "$ENCRYPTED_WORKFLOW_JSON" ]]; then
    log_error "Encrypted workflow backup missing"
    exit 1
fi
if [[ ! -s "$ENCRYPTED_CREDENTIALS_JSON" ]]; then
    log_error "Encrypted credentials backup missing"
    exit 1
fi

WORKFLOW_JSON_JQ_PATH=$(convert_path_for_jq "$ENCRYPTED_WORKFLOW_JSON")
if ! jq empty "$WORKFLOW_JSON_JQ_PATH" >/dev/null 2>"$TEST_BACKUP_DIR/workflows_jq_error.log"; then
    jq_error=$(<"$TEST_BACKUP_DIR/workflows_jq_error.log")
    log_error "Encrypted workflow JSON is invalid"
    [[ -n "$jq_error" ]] && log_error "$jq_error"
    exit 1
fi
rm -f "$TEST_BACKUP_DIR/workflows_jq_error.log" 2>/dev/null || true
log_success "Encrypted workflow JSON is valid"

ENCRYPTED_CREDENTIALS_JQ=$(convert_path_for_jq "$ENCRYPTED_CREDENTIALS_JSON")
if ! jq empty "$ENCRYPTED_CREDENTIALS_JQ" >/dev/null 2>"$TEST_BACKUP_DIR/credentials_jq_error.log"; then
    cred_error=$(<"$TEST_BACKUP_DIR/credentials_jq_error.log")
    log_error "Encrypted credentials JSON is invalid"
    [[ -n "$cred_error" ]] && log_error "$cred_error"
    exit 1
fi
rm -f "$TEST_BACKUP_DIR/credentials_jq_error.log" 2>/dev/null || true

if grep -q "test-password" "$ENCRYPTED_CREDENTIALS_JSON"; then
    log_error "Encrypted credential backup contains plaintext password"
    exit 1
fi
log_success "Encrypted credential JSON passes validation"

# 5. Run decrypted backup via n8n-push.sh
DECRYPTED_BACKUP_DIR="$TEST_BACKUP_DIR/local-decrypted"
mkdir -p "$DECRYPTED_BACKUP_DIR"

DECRYPTED_BACKUP_DIR_ARG=$(convert_path_for_jq "$DECRYPTED_BACKUP_DIR")

log_info "Running decrypted backup through n8n-push.sh..."
DECRYPTED_BACKUP_LOG="$TEST_BACKUP_DIR/backup_decrypted.log"
if ! MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' bash "$PROJECT_ROOT/n8n-push.sh" \
    --action backup \
    --container "$TEST_CONTAINER" \
    --workflows 1 \
    --credentials 1 \
    --environment 0 \
    --local-path "$DECRYPTED_BACKUP_DIR_ARG" \
    --config /dev/null \
    --decrypt false \
    --defaults \
    "${CLI_VERBOSE_FLAGS[@]}" \
    >"$DECRYPTED_BACKUP_LOG" 2>&1; then
    log_error "Decrypted backup run failed"
    log_error "See $DECRYPTED_BACKUP_LOG for details"
    exit 1
fi
log_success "Decrypted backup completed"

DECRYPTED_WORKFLOW_JSON="$DECRYPTED_BACKUP_DIR/workflows.json"
DECRYPTED_CREDENTIALS_JSON="$DECRYPTED_BACKUP_DIR/credentials.json"

if [[ ! -s "$DECRYPTED_WORKFLOW_JSON" ]]; then
    log_error "Decrypted workflow backup missing"
    exit 1
fi
if [[ ! -s "$DECRYPTED_CREDENTIALS_JSON" ]]; then
    log_error "Decrypted credentials backup missing"
    exit 1
fi

DECRYPTED_WORKFLOW_JQ=$(convert_path_for_jq "$DECRYPTED_WORKFLOW_JSON")
if ! jq empty "$DECRYPTED_WORKFLOW_JQ" >/dev/null 2>"$TEST_BACKUP_DIR/decrypted_workflows_jq_error.log"; then
    jq_error=$(<"$TEST_BACKUP_DIR/decrypted_workflows_jq_error.log")
    log_error "Decrypted workflow JSON is invalid"
    [[ -n "$jq_error" ]] && log_error "$jq_error"
    exit 1
fi
rm -f "$TEST_BACKUP_DIR/decrypted_workflows_jq_error.log" 2>/dev/null || true

DECRYPTED_CREDENTIALS_JQ=$(convert_path_for_jq "$DECRYPTED_CREDENTIALS_JSON")
if ! jq empty "$DECRYPTED_CREDENTIALS_JQ" >/dev/null 2>"$TEST_BACKUP_DIR/decrypted_credentials_jq_error.log"; then
    cred_error=$(<"$TEST_BACKUP_DIR/decrypted_credentials_jq_error.log")
    log_error "Decrypted credentials JSON is invalid"
    [[ -n "$cred_error" ]] && log_error "$cred_error"
    exit 1
fi
rm -f "$TEST_BACKUP_DIR/decrypted_credentials_jq_error.log" 2>/dev/null || true

DECRYPTED_USER=$(jq -r '.[0].data.user // empty' "$DECRYPTED_CREDENTIALS_JQ" || true)
DECRYPTED_PASSWORD=$(jq -r '.[0].data.password // empty' "$DECRYPTED_CREDENTIALS_JQ" || true)
if [[ "$DECRYPTED_USER" != "test-user" || "$DECRYPTED_PASSWORD" != "test-password" ]]; then
    log_error "Decrypted credential contents did not match expected values"
    exit 1
fi
log_success "Decrypted credential JSON contains expected values"

# 6. Test workflow restore using encrypted backup
log_info "Testing workflow restore from encrypted backup..."

TEMP_RESTORE_WORKFLOWS="/tmp/workflows-restore.json"
docker exec "$TEST_CONTAINER" rm -f "$TEMP_RESTORE_WORKFLOWS" >/dev/null 2>&1 || true
RESTORE_WORKFLOW_LOG="$TEST_BACKUP_DIR/restore_workflow.log"

if ! docker cp "${WORKFLOW_JSON_JQ_PATH}" "$TEST_CONTAINER:$TEMP_RESTORE_WORKFLOWS" >/dev/null 2>&1; then
    log_error "Failed to copy encrypted workflow backup into container"
    exit 1
fi

log_success "Encrypted workflow backup copied into container"

if ! docker exec "$TEST_CONTAINER" n8n import:workflow --input "$TEMP_RESTORE_WORKFLOWS" >"$RESTORE_WORKFLOW_LOG" 2>&1; then
    log_error "Failed to restore workflows from encrypted backup"
    if [[ -s "$RESTORE_WORKFLOW_LOG" ]]; then
        while IFS= read -r line; do
            log_error "$line"
        done <"$RESTORE_WORKFLOW_LOG"
    fi
    exit 1
fi
log_success "Workflow restore from encrypted backup succeeded"

# 7. Verify restored workflow
log_info "Verifying restored workflow..."
TEMP_VERIFY=$(docker exec "$TEST_CONTAINER" mktemp -p /tmp)
docker exec "$TEST_CONTAINER" n8n export:workflow --all --output "$TEMP_VERIFY"
WORKFLOW_COUNT=$(docker exec "$TEST_CONTAINER" jq 'length' "$TEMP_VERIFY")

if [ "$WORKFLOW_COUNT" -lt 1 ]; then
    log_error "No workflows found after restore"
    exit 1
fi
log_success "Verified $WORKFLOW_COUNT workflow(s) after restore"

# 8. Test script accessibility
log_info "Verifying n8n-push.sh is executable..."
if [ ! -f "$PROJECT_ROOT/n8n-push.sh" ]; then
    log_error "n8n-push.sh not found"
    exit 1
fi

if [ ! -x "$PROJECT_ROOT/n8n-push.sh" ]; then
    log_error "n8n-push.sh is not executable"
    exit 1
fi
log_success "n8n-push.sh is executable"

# Summary
echo ""
log_success "═══════════════════════════════════════"
log_success "All backup/restore tests passed! ✓"
log_success "═══════════════════════════════════════"

exit 0
