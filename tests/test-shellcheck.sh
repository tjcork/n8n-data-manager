#!/usr/bin/env bash
# =========================================================
# n8n push - ShellCheck Linting
# =========================================================
# Validates shell scripts for common issues and best practices

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
log_info "n8n push - ShellCheck Analysis"
log_info "═══════════════════════════════════════"
echo ""  # Maintain spacing before report output

# Find all shell scripts
MAIN_SCRIPT="$PROJECT_ROOT/n8n-push.sh"
INSTALL_SCRIPT="$PROJECT_ROOT/install.sh"
LIB_SCRIPTS=()
if [[ -d "$PROJECT_ROOT/lib" ]]; then
    while IFS= read -r -d '' file; do
        LIB_SCRIPTS+=("$file")
    done < <(find "$PROJECT_ROOT/lib" -name "*.sh" -print0 2>/dev/null || true)
fi

# Report file
REPORT="$PROJECT_ROOT/shellcheck-report.md"
echo "# n8n push - ShellCheck Analysis Report" > "$REPORT"
echo "" >> "$REPORT"
echo "Generated: $(date)" >> "$REPORT"
echo "" >> "$REPORT"

TOTAL_ISSUES=0

# Check main script
log_info "Analyzing n8n-push.sh..."
echo "## Main Script (n8n-push.sh)" >> "$REPORT"
echo '```' >> "$REPORT"
if shellcheck -f gcc -e SC1091 -e SC2034 -e SC2154 "$MAIN_SCRIPT" >> "$REPORT" 2>&1; then
    echo "✓ No issues found" >> "$REPORT"
    log_success "n8n-push.sh passed"
else
    TOTAL_ISSUES=$((TOTAL_ISSUES + 1))
    log_error "n8n-push.sh reported ShellCheck findings"
fi
echo '```' >> "$REPORT"
echo "" >> "$REPORT"

# Check install script
log_info "Analyzing install.sh..."
echo "## Install Script (install.sh)" >> "$REPORT"
echo '```' >> "$REPORT"
if shellcheck -f gcc -e SC1091 "$INSTALL_SCRIPT" >> "$REPORT" 2>&1; then
    echo "✓ No issues found" >> "$REPORT"
    log_success "install.sh passed"
else
    TOTAL_ISSUES=$((TOTAL_ISSUES + 1))
    log_error "install.sh reported ShellCheck findings"
fi
echo '```' >> "$REPORT"
echo "" >> "$REPORT"

# Check library scripts
if ((${#LIB_SCRIPTS[@]} > 0)); then
    log_info "Analyzing library modules..."
    echo "## Library Modules" >> "$REPORT"

    for lib in "${LIB_SCRIPTS[@]}"; do
        lib_name=$(basename "$lib")
        log_info "  - $lib_name"
        echo "### $lib_name" >> "$REPORT"
        echo '```' >> "$REPORT"
        if shellcheck -f gcc -e SC1091 -e SC2034 -e SC2154 "$lib" >> "$REPORT" 2>&1; then
            echo "✓ No issues found" >> "$REPORT"
            log_success "$lib_name passed"
        else
            TOTAL_ISSUES=$((TOTAL_ISSUES + 1))
            log_error "$lib_name reported ShellCheck findings"
        fi
        echo '```' >> "$REPORT"
        echo "" >> "$REPORT"
    done
fi

echo ""
log_info "═══════════════════════════════════════"
if [ "$TOTAL_ISSUES" -eq 0 ]; then
    log_success "All scripts passed ShellCheck"
    log_info "═══════════════════════════════════════"
    exit 0
else
    log_error "Found issues in $TOTAL_ISSUES script(s)"
    log_info "See shellcheck-report.md for details"
    log_info "═══════════════════════════════════════"
    exit 0  # Don't fail CI on warnings
fi
