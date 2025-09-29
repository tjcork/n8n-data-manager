#!/usr/bin/env bash
# =========================================================
# lib/common.sh - Common utilities for n8n-manager
# =========================================================
# Core utilities: logging, configuration, dependencies, Git helpers
# Used by all other modules in the n8n-manager system

set -Eeuo pipefail
IFS=$'\n\t'

# --- Global variables ---
VERSION="4.0.0"
DEBUG_TRACE=${DEBUG_TRACE:-false} # Set to true for trace debugging

# ANSI colors for better UI (using printf for robustness)
printf -v RED     '\033[0;31m'
printf -v GREEN   '\033[0;32m'
printf -v BLUE    '\033[0;34m'
printf -v YELLOW  '\033[1;33m'
printf -v NC      '\033[0m' # No Color
printf -v BOLD    '\033[1m'
printf -v DIM     '\033[2m'

# --- Git Helper Functions ---
# These functions isolate Git operations to avoid parse errors
git_add() {
    local repo_dir="$1"
    local target="$2"
    git -C "$repo_dir" add "$target"
    return $?
}

git_commit() {
    local repo_dir="$1"
    local message="$2"
    git -C "$repo_dir" commit -m "$message"
    return $?
}

git_push() {
    local repo_dir="$1"
    local remote="$2"
    local branch="$3"
    git -C "$repo_dir" push -u "$remote" "$branch"
    return $?
}

# --- Storage Value Formatting ---
format_storage_value() {
    local value="$1"
    case "$value" in
        0) echo "disabled" ;;
        1) echo "local" ;;
        2) echo "remote" ;;
        *) echo "unknown" ;;
    esac
}

# --- Debug/Trace Function ---
trace_cmd() {
    if $DEBUG_TRACE; then
        echo -e "\033[0;35m[TRACE] Running command: $*\033[0m" >&2
        "$@"
        local ret=$?
        echo -e "\033[0;35m[TRACE] Command returned: $ret\033[0m" >&2
        return $ret
    else
        "$@"
        return $?
    fi
}

# Simplified and sanitized log function to avoid command not found errors
log() {
    # Define parameters
    local level="$1"
    local message="$2"
    
    # Skip debug messages if verbose is not enabled
    if [ "$level" = "DEBUG" ] && [ "$verbose" != "true" ]; then 
        return 0;
    fi
    
    # Set color based on level
    local color=""
    local prefix=""
    local to_stderr=false
    
    if [ "$level" = "DEBUG" ]; then
        color="$DIM"
        prefix="[DEBUG]"
    elif [ "$level" = "INFO" ]; then
        color="$BLUE"
        prefix="==>"
    elif [ "$level" = "WARN" ]; then
        color="$YELLOW"
        prefix="[WARNING]"
    elif [ "$level" = "ERROR" ]; then
        color="$RED"
        prefix="[ERROR]"
        to_stderr=true
    elif [ "$level" = "SUCCESS" ]; then
        color="$GREEN"
        prefix="[SUCCESS]"
    elif [ "$level" = "HEADER" ]; then
        color="$BLUE$BOLD"
        message="\n$message\n"
    elif [ "$level" = "DRYRUN" ]; then
        color="$YELLOW"
        prefix="[DRY RUN]"
    else
        prefix="[$level]"
    fi
    
    # Format message
    local formatted="${color}${prefix} ${message}${NC}"
    local plain="$(date +'%Y-%m-%d %H:%M:%S') ${prefix} ${message}"
    
    # Output
    if [ "$to_stderr" = "true" ]; then
        echo -e "$formatted" >&2
    else
        echo -e "$formatted"
    fi
    
    # Log to file if specified
    if [ -n "${log_file:-}" ]; then
        echo "$plain" >> "$log_file"
    fi
    
    return 0
}

# --- Helper Functions (using new log function) ---

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_host_dependencies() {
    log HEADER "Checking host dependencies..."
    local missing_deps=""
    if ! command_exists docker; then
        missing_deps="$missing_deps docker"
    fi
    if ! command_exists git; then
        missing_deps="$missing_deps git"
    fi
    if ! command_exists curl; then # Added curl check
        missing_deps="$missing_deps curl"
    fi
    if ! command_exists python3; then # Added python3 for JSON parsing
        missing_deps="$missing_deps python3"
    fi

    if [ -n "$missing_deps" ]; then
        log ERROR "Missing required host dependencies:$missing_deps"
        log INFO "Please install the missing dependencies and try again."
        exit 1
    fi
    log SUCCESS "All required host dependencies are available!"
}

load_config() {
    local file_to_load=""
    local config_found=false
    
    # Priority: explicit config → local config → user config
    if [[ -n "$config_file" ]]; then
        file_to_load="$config_file"
    elif [[ -f "$LOCAL_CONFIG_FILE" ]]; then
        file_to_load="$LOCAL_CONFIG_FILE"
    elif [[ -f "$USER_CONFIG_FILE" ]]; then
        file_to_load="$USER_CONFIG_FILE"
    fi
    
    # Expand tilde if present
    if [[ -n "$file_to_load" ]]; then
        file_to_load="${file_to_load/#\~/$HOME}"
    fi

    # Load configuration file if it exists
    if [[ -f "$file_to_load" ]]; then
        config_found=true
        log INFO "Loading configuration from: $file_to_load"
        
        # Source the config file safely (filter out comments and empty lines)
        if ! source <(grep -vE '^\s*(#|$)' "$file_to_load" 2>/dev/null || true); then
            log ERROR "Failed to load configuration from: $file_to_load"
            return 1
        fi
        
        # === GITHUB SETTINGS ===
        # Apply config values to global variables (use config file values if runtime vars not set)
        if [[ -z "$github_token" && -n "${GITHUB_TOKEN:-}" ]]; then
            github_token="$GITHUB_TOKEN"
        fi
        
        if [[ -z "$github_repo" && -n "${GITHUB_REPO:-}" ]]; then
            github_repo="$GITHUB_REPO"
        fi
        
        if [[ -z "$github_branch" && -n "${GITHUB_BRANCH:-}" ]]; then
            github_branch="$GITHUB_BRANCH"
        else
            github_branch="${github_branch:-main}"  # Set default if not configured anywhere
        fi
        
        # === CONTAINER SETTINGS ===
        if [[ -z "$container" && -n "${DEFAULT_CONTAINER:-}" ]]; then
            container="$DEFAULT_CONTAINER"
        fi
        
        # Keep reference to default container from config
        if [[ -n "${DEFAULT_CONTAINER:-}" ]]; then
            default_container="$DEFAULT_CONTAINER"
        fi
        
        # === STORAGE SETTINGS ===
        # Handle workflows storage with flexible input (numeric or descriptive)
        if [[ -z "$workflows" && -n "${WORKFLOWS:-}" ]]; then
            local workflows_config="$WORKFLOWS"
            workflows_config=$(echo "$workflows_config" | tr '[:upper:]' '[:lower:]')
            case "$workflows_config" in
                0|disabled) workflows=0 ;;
                1|local) workflows=1 ;;
                2|remote) workflows=2 ;;
                *) 
                    log WARN "Invalid WORKFLOWS value in config: '$workflows_config'. Must be 0/disabled, 1/local, or 2/remote. Using default: 1 (local)"
                    workflows=1
                    ;;
            esac
        fi
        
        # Handle credentials storage with flexible input (numeric or descriptive)
        if [[ -z "$credentials" && -n "${CREDENTIALS:-}" ]]; then
            local credentials_config="$CREDENTIALS"
            credentials_config=$(echo "$credentials_config" | tr '[:upper:]' '[:lower:]')
            case "$credentials_config" in
                0|disabled) credentials=0 ;;
                1|local) credentials=1 ;;
                2|remote) credentials=2 ;;
                *) 
                    log WARN "Invalid CREDENTIALS value in config: '$credentials_config'. Must be 0/disabled, 1/local, or 2/remote. Using default: 1 (local)"
                    credentials=1
                    ;;
            esac
        fi
        
        # === BOOLEAN SETTINGS ===
        # Handle dated_backups boolean config
        if [[ -z "$dated_backups" && -n "${DATED_BACKUPS:-}" ]]; then
            local dated_backups_config="$DATED_BACKUPS"
            dated_backups_config=$(echo "$dated_backups_config" | tr '[:upper:]' '[:lower:]')
            case "$dated_backups_config" in
                true|1|yes|on) dated_backups=true ;;
                false|0|no|off) dated_backups=false ;;
                *) 
                    log WARN "Invalid DATED_BACKUPS value in config: '$dated_backups_config'. Must be true/false. Using default: false"
                    dated_backups=false
                    ;;
            esac
        fi
        
        # Handle folder_structure boolean config
        if [[ -z "$folder_structure" && -n "${FOLDER_STRUCTURE:-}" ]]; then
            local folder_structure_config="$FOLDER_STRUCTURE"
            folder_structure_config=$(echo "$folder_structure_config" | tr '[:upper:]' '[:lower:]')
            case "$folder_structure_config" in
                true|1|yes|on) folder_structure=true ;;
                false|0|no|off) folder_structure=false ;;
                *) 
                    log WARN "Invalid FOLDER_STRUCTURE value in config: '$folder_structure_config'. Must be true/false. Using default: false"
                    folder_structure=false
                    ;;
            esac
        fi
        
        # Handle verbose boolean config
        if [[ -z "$verbose" && -n "${VERBOSE:-}" ]]; then
            local verbose_config="$VERBOSE"
            verbose_config=$(echo "$verbose_config" | tr '[:upper:]' '[:lower:]')
            case "$verbose_config" in
                true|1|yes|on) verbose=true ;;
                false|0|no|off) verbose=false ;;
                *) 
                    log WARN "Invalid VERBOSE value in config: '$verbose_config'. Must be true/false. Using default: false"
                    verbose=false
                    ;;
            esac
        fi
        
        # Handle dry_run boolean config
        if [[ -z "$dry_run" && -n "${DRY_RUN:-}" ]]; then
            local dry_run_config="$DRY_RUN"
            dry_run_config=$(echo "$dry_run_config" | tr '[:upper:]' '[:lower:]')
            case "$dry_run_config" in
                true|1|yes|on) dry_run=true ;;
                false|0|no|off) dry_run=false ;;
                *) 
                    log WARN "Invalid DRY_RUN value in config: '$dry_run_config'. Must be true/false. Using default: false"
                    dry_run=false
                    ;;
            esac
        fi
        
        # === PATH SETTINGS ===
        if [[ -z "$local_backup_path" && -n "${LOCAL_BACKUP_PATH:-}" ]]; then
            local_backup_path="$LOCAL_BACKUP_PATH"
        fi
        
        if [[ -z "$local_rotation_limit" && -n "${LOCAL_ROTATION_LIMIT:-}" ]]; then
            local_rotation_limit="$LOCAL_ROTATION_LIMIT"
        fi
        
        # === N8N API SETTINGS ===
        if [[ -z "$n8n_base_url" && -n "${N8N_BASE_URL:-}" ]]; then
            n8n_base_url="$N8N_BASE_URL"
        fi
        
        if [[ -z "$n8n_api_key" && -n "${N8N_API_KEY:-}" ]]; then
            n8n_api_key="$N8N_API_KEY"
        fi
        
        if [[ -z "$n8n_email" && -n "${N8N_EMAIL:-}" ]]; then
            n8n_email="$N8N_EMAIL"
        fi
        
        if [[ -z "$n8n_password" && -n "${N8N_PASSWORD:-}" ]]; then
            n8n_password="$N8N_PASSWORD"
        fi
        
        # === OTHER SETTINGS ===
        if [[ -z "$restore_type" && -n "${RESTORE_TYPE:-}" ]]; then
            restore_type="$RESTORE_TYPE"
        fi
        
        if [[ -z "$log_file" && -n "${LOG_FILE:-}" ]]; then
            log_file="$LOG_FILE"
        fi
        
    elif [[ -n "$config_file" ]]; then
        log WARN "Configuration file specified but not found: '$config_file'"
    else
        log DEBUG "No configuration file found. Checked: '$LOCAL_CONFIG_FILE' and '$USER_CONFIG_FILE'"
    fi
    
    # === SET DEFAULTS FOR UNSET VALUES ===
    # Only set defaults if no value was provided via command line or config
    
    # Set storage defaults
    if [[ -z "$workflows" ]]; then
        workflows=1  # Default to local
    fi
    
    if [[ -z "$credentials" ]]; then
        credentials=1  # Default to local
    fi
    
    # Set path defaults
    if [[ -z "$local_backup_path" ]]; then
        local_backup_path="$HOME/n8n-backup"
    fi
    
    if [[ -z "$local_rotation_limit" ]]; then
        local_rotation_limit="10"
    fi
    
    # Set other defaults
    if [[ -z "$restore_type" ]]; then
        restore_type="all"
    fi
    
    if [[ -z "$github_branch" ]]; then
        github_branch="main"
    fi
    
    # === LOG FILE VALIDATION ===
    if [[ -n "$log_file" ]]; then
        # Ensure log file path is absolute
        if [[ "$log_file" != /* ]]; then
            log WARN "Log file path '$log_file' is not absolute. Converting to absolute path."
            log_file="$(pwd)/$log_file"
        fi
        
        # Ensure log file directory exists and is writable
        local log_dir
        log_dir="$(dirname "$log_file")"
        if ! mkdir -p "$log_dir" 2>/dev/null; then
            log ERROR "Cannot create directory for log file: '$log_dir'"
            exit 1
        fi
        
        if ! touch "$log_file" 2>/dev/null; then
            log ERROR "Log file is not writable: '$log_file'"
            exit 1
        fi
        
        log INFO "Logging output to: $log_file"
    fi
    
    # === DEBUG OUTPUT ===
    if [[ "$config_found" == "true" ]]; then
        log DEBUG "Configuration loaded successfully"
        log DEBUG "Storage: workflows=($workflows) $(format_storage_value $workflows), credentials=($credentials) $(format_storage_value $credentials)"
    else
        log DEBUG "No configuration file loaded, using defaults"
    fi
}

# Utility functions that other modules need
check_github_access() {
    local token="$1"
    local repo="$2"
    
    log DEBUG "Testing GitHub access to repository: $repo"
    
    local response
    if ! response=$(curl -s -w "%{http_code}" -H "Authorization: token $token" \
                          "https://api.github.com/repos/$repo" 2>/dev/null); then
        return 1
    fi
    
    local http_code="${response: -3}"
    local body="${response%???}"
    
    case "$http_code" in
        200) 
            log DEBUG "GitHub access test successful"
            return 0 ;;
        404)
            log ERROR "Repository '$repo' not found or not accessible with provided token"
            return 1 ;;
        401|403)
            log ERROR "GitHub access denied. Check your token permissions."
            return 1 ;;
        *)
            log ERROR "GitHub API returned HTTP $http_code"
            return 1 ;;
    esac
}

dockExec() {
    local container_id="$1"
    local cmd="$2"
    local is_dry_run=$3
    local output=""
    local exit_code=0

    if $is_dry_run; then
        log DRYRUN "Would execute in container $container_id: $cmd"
        return 0
    else
        log DEBUG "Executing in container $container_id: $cmd"
        output=$(docker exec "$container_id" sh -c "$cmd" 2>&1) || exit_code=$?
        
        # Use explicit string comparison to avoid empty command errors
        if [ "$verbose" = "true" ] && [ -n "$output" ]; then
            log DEBUG "Container output:\n$(echo "$output" | sed 's/^/  /')"
        fi
        
        if [ $exit_code -ne 0 ]; then
            log ERROR "Command failed in container (Exit Code: $exit_code): $cmd"
            if [ "$verbose" != "true" ] && [ -n "$output" ]; then
                log ERROR "Container output:\n$(echo "$output" | sed 's/^/  /')"
            fi
            return 1
        fi
        
        return 0
    fi
}

timestamp() {
    date "+%Y-%m-%d_%H-%M-%S"
}