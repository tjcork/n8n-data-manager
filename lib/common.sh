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
    if [ -n "$log_file" ]; then
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
    
    # Priority: explicit config → local config → user config
    if [ -n "$config_file" ]; then
        file_to_load="$config_file"
    elif [ -f "$LOCAL_CONFIG_FILE" ]; then
        file_to_load="$LOCAL_CONFIG_FILE"
    elif [ -f "$USER_CONFIG_FILE" ]; then
        file_to_load="$USER_CONFIG_FILE"
    fi
    
    # Expand tilde if present
    file_to_load="${file_to_load/#\~/$HOME}"

    if [ -f "$file_to_load" ]; then
        log INFO "Loaded configuration from $file_to_load"
        source <(grep -vE '^\s*(#|$)' "$file_to_load" 2>/dev/null || true)
        
        # Apply config values to runtime variables (only if not already set)
        github_token=${github_token:-${GITHUB_TOKEN:-}}
        github_repo=${github_repo:-${GITHUB_REPO:-}}
        github_branch=${github_branch:-${GITHUB_BRANCH:-main}}
        container=${container:-${DEFAULT_CONTAINER:-}}
        default_container=${DEFAULT_CONTAINER:-}
        
        # Handle boolean configs properly - only set if config file has explicit value
        if [[ -z "$dated_backups" ]] && [[ -n "${DATED_BACKUPS:-}" ]]; then 
            case "${DATED_BACKUPS,,}" in  # Convert to lowercase for comparison
                true|1|yes|on) dated_backups=true ;;
                false|0|no|off) dated_backups=false ;;
                *) log WARN "Invalid DATED_BACKUPS value: ${DATED_BACKUPS}. Using default: false"
                   dated_backups=false ;;
            esac
        fi
        
        # Storage settings - flexible format: WORKFLOWS=0/1/2 or disabled/local/remote
        # 0=disabled, 1=local storage, 2=remote Git repository
        
        # Load workflows configuration (default: 1=local)
        workflows_raw=${workflows:-${WORKFLOWS:-1}}
        case "${workflows_raw,,}" in  # Convert to lowercase
            0|disabled) workflows=0 ;;
            1|local) workflows=1 ;;
            2|remote) workflows=2 ;;
            *) log WARN "Invalid workflows value: $workflows_raw. Using default (1) local"
               workflows=1 ;;
        esac
        
        # Load credentials configuration (default: 1=local)
        credentials_raw=${credentials:-${CREDENTIALS:-1}}
        case "${credentials_raw,,}" in  # Convert to lowercase
            0|disabled) credentials=0 ;;
            1|local) credentials=1 ;;
            2|remote) credentials=2 ;;
            *) log WARN "Invalid credentials value: $credentials_raw. Using default (1) local"
               credentials=1 ;;
        esac
        
        local_backup_path=${local_backup_path:-${LOCAL_BACKUP_PATH:-$HOME/n8n-backup}}
        local_rotation_limit=${local_rotation_limit:-${LOCAL_ROTATION_LIMIT:-10}}
        
        log DEBUG "Config loaded - workflows: ($workflows) $(format_storage_value $workflows), credentials: ($credentials) $(format_storage_value $credentials)"
        
        # Handle folder_structure boolean config
        if [[ -z "$folder_structure" ]] && [[ -n "${FOLDER_STRUCTURE:-}" ]]; then
            case "${FOLDER_STRUCTURE,,}" in  # Convert to lowercase for comparison
                true|1|yes|on) folder_structure=true ;;
                false|0|no|off) folder_structure=false ;;
                *) log WARN "Invalid FOLDER_STRUCTURE value: ${FOLDER_STRUCTURE}. Using default: false"
                   folder_structure=false ;;
            esac
        fi
        
        # n8n API settings
        n8n_base_url=${n8n_base_url:-${N8N_BASE_URL:-}}
        n8n_api_key=${n8n_api_key:-${N8N_API_KEY:-}}
        n8n_email=${n8n_email:-${N8N_EMAIL:-}}
        n8n_password=${n8n_password:-${N8N_PASSWORD:-}}
        
        # Other settings
        restore_type=${restore_type:-${RESTORE_TYPE:-all}}
        
        # Handle verbose boolean config
        if [[ -z "$verbose" ]] && [[ -n "${VERBOSE:-}" ]]; then
            case "${VERBOSE,,}" in  # Convert to lowercase for comparison
                true|1|yes|on) verbose=true ;;
                false|0|no|off) verbose=false ;;
                *) log WARN "Invalid VERBOSE value: ${VERBOSE}. Using default: false"
                   verbose=false ;;
            esac
        fi
        
        # Handle dry_run boolean config
        if [[ -z "$dry_run" ]] && [[ -n "${DRY_RUN:-}" ]]; then
            case "${DRY_RUN,,}" in  # Convert to lowercase for comparison
                true|1|yes|on) dry_run=true ;;
                false|0|no|off) dry_run=false ;;
                *) log WARN "Invalid DRY_RUN value: ${DRY_RUN}. Using default: false"
                   dry_run=false ;;
            esac
        fi
        
        
        log_file=${log_file:-${LOG_FILE:-}}
        
    elif [ -n "$config_file" ]; then
        log WARN "Configuration file specified but not found: $config_file"
    else
        log DEBUG "No configuration file found (checked: local './.config' and '$USER_CONFIG_FILE')"
    fi
    
    if [ -n "$log_file" ] && [[ "$log_file" != /* ]]; then
        log WARN "Log file path '$log_file' is not absolute. Prepending current directory."
        log_file="$(pwd)/$log_file"
    fi
    
    if [ -n "$log_file" ]; then
        log DEBUG "Ensuring log file exists and is writable: $log_file"
        mkdir -p "$(dirname "$log_file")" || { log ERROR "Could not create directory for log file: $(dirname "$log_file")"; exit 1; }
        touch "$log_file" || { log ERROR "Log file is not writable: $log_file"; exit 1; }
        log INFO "Logging output also to: $log_file"
    fi
    
    # Validate folder structure configuration
    if [[ "${folder_structure_flag:-false}" == "true" ]] || [[ "$folder_structure" == "true" ]]; then
        if [[ -z "$n8n_base_url" ]]; then
            log ERROR "Folder structure enabled but n8n URL not provided. Set n8n_base_url via --n8n-url or config file"
            exit 1
        fi
        if [[ -z "$n8n_api_key" ]]; then
            log ERROR "Folder structure enabled but n8n API key not provided. Set n8n_api_key via --n8n-api-key or config file"
            exit 1
        fi
        log INFO "Folder structure mirroring enabled with n8n instance: $n8n_base_url"
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