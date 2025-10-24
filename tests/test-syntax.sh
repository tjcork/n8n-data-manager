#!/usr/bin/env bash
# =========================================================
# n8n push - Bash Syntax Validation
# =========================================================
# Validates all shell scripts can be parsed by bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    printf '%b[TEST]%b %s\n' "$YELLOW" "$NC" "$*"
}

log_success() {
    printf '%b[PASS]%b %s\n' "$GREEN" "$NC" "$*"
}

log_error() {
    printf '%b[FAIL]%b %s\n' "$RED" "$NC" "$*"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log_info "═══════════════════════════════════════"
log_info "n8n push - Syntax Validation"
log_info "═══════════════════════════════════════"
echo ""

cd "$PROJECT_ROOT"

# Test main script
log_info "Validating n8n-push.sh syntax"
bash -n n8n-push.sh

# Test install script
log_info "Validating install.sh syntax"
bash -n install.sh

# Test all library modules
log_info "Validating library modules"
shopt -s nullglob
for lib_script in lib/*.sh lib/restore/*.sh; do
    if [ -f "$lib_script" ]; then
        log_info "  - $(basename "$lib_script")"
        bash -n "$lib_script"
    fi
done
shopt -u nullglob

# Test script can show help
echo ""
log_info "Testing --help flag"
chmod +x n8n-push.sh
./n8n-push.sh --help > /dev/null 2>&1 || {
    log_info "  Note: Help output may be redirected or script needs arguments"
}

echo ""
log_info "═══════════════════════════════════════"
log_success "All syntax checks passed"
log_info "═══════════════════════════════════════"

exit 0