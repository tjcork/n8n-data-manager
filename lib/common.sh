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

git_commit_name=""
git_commit_email=""

# Default location for storing credentials inside Git repositories
: "${credentials_folder_name:=.credentials}"

# Ensure configuration source trackers exist even when scripts source this module standalone
: "${workflows_source:=unset}"
: "${credentials_source:=unset}"
: "${local_backup_path_source:=unset}"
: "${local_rotation_limit_source:=unset}"
: "${dated_backups_source:=unset}"
: "${dry_run_source:=unset}"
: "${folder_structure_source:=unset}"
: "${credentials_encrypted_source:=unset}"

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
        to_stderr=true
    elif [ "$level" = "INFO" ]; then
        color="$BLUE"
        prefix="==>"
    elif [ "$level" = "WARN" ]; then
        color="$YELLOW"
        prefix="[WARNING]"
        to_stderr=true
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

# --- Filename Utilities ---
sanitize_filename_component() {
    local input="$1"
    local max_len="${2:-152}"

    local cleaned
    cleaned="$(printf '%s' "$input" | tr -d '\000')"
    cleaned="$(printf '%s' "$cleaned" | tr '\r\n\t' '   ')"
    cleaned="$(printf '%s' "$cleaned" | sed -e 's/[[:cntrl:]]//g' -e 's#[\\/:*?"<>|]#-#g')"
    cleaned="$(printf '%s' "$cleaned" | sed -e 's/[[:space:]]\+/ /g' -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//')"

    while [[ "$cleaned" =~ [[:space:].]$ ]]; do
        cleaned="${cleaned%?}"
    done

    if (( max_len > 0 && ${#cleaned} > max_len )); then
        cleaned="${cleaned:0:max_len}"
        while [[ "$cleaned" =~ [[:space:].]$ ]]; do
            cleaned="${cleaned%?}"
        done
    fi

    printf '%s\n' "$cleaned"
}

sanitize_workflow_filename_part() {
    local raw="$1"
    local fallback="$2"

    local sanitized
    sanitized="$(sanitize_filename_component "$raw" 152)"

    if [[ -z "$sanitized" ]]; then
        local fallback_value="Workflow ${fallback:-}";
        sanitized="$(sanitize_filename_component "$fallback_value" 152)"
    fi

    if [[ -z "$sanitized" ]]; then
        sanitized="Workflow"
    fi

    printf '%s\n' "$sanitized"
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
    if ! command_exists jq; then # Added jq for JSON parsing
        missing_deps="$missing_deps jq"
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
        
        # Source the config file safely (normalize CRLF and filter out comments and empty lines)
        if ! source <(tr -d '\r' < "$file_to_load" | grep -vE '^\s*(#|$)' 2>/dev/null || true); then
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
            # Clean up the value - remove quotes and whitespace
            workflows_config=$(echo "$workflows_config" | tr -d '"\047' | tr '[:upper:]' '[:lower:]' | xargs)
            
            if [[ "$workflows_config" == "0" || "$workflows_config" == "disabled" ]]; then
                workflows=0
                workflows_source="config"
            elif [[ "$workflows_config" == "1" || "$workflows_config" == "local" ]]; then
                workflows=1
                workflows_source="config"
            elif [[ "$workflows_config" == "2" || "$workflows_config" == "remote" ]]; then
                workflows=2
                workflows_source="config"
            else
                log WARN "Invalid WORKFLOWS value in config: '$workflows_config'. Must be 0/disabled, 1/local, or 2/remote. Using default: 1 (local)"
                workflows=1
                workflows_source="default"
            fi
        fi
        
        # Handle credentials storage with flexible input (numeric or descriptive)
        if [[ -z "$credentials" && -n "${CREDENTIALS:-}" ]]; then
            local credentials_config="$CREDENTIALS"
            # Clean up the value - remove quotes and whitespace
            credentials_config=$(echo "$credentials_config" | tr -d '"\047' | tr '[:upper:]' '[:lower:]' | xargs)
            
            if [[ "$credentials_config" == "0" || "$credentials_config" == "disabled" ]]; then
                credentials=0
                credentials_source="config"
            elif [[ "$credentials_config" == "1" || "$credentials_config" == "local" ]]; then
                credentials=1
                credentials_source="config"
            elif [[ "$credentials_config" == "2" || "$credentials_config" == "remote" ]]; then
                credentials=2
                credentials_source="config"
            else
                log WARN "Invalid CREDENTIALS value in config: '$credentials_config'. Must be 0/disabled, 1/local, or 2/remote. Using default: 1 (local)"
                credentials=1
                credentials_source="default"
            fi
        fi
        
        # === BOOLEAN SETTINGS ===
        # Handle dated_backups boolean config
        if [[ -z "$dated_backups" && -n "${DATED_BACKUPS:-}" ]]; then
            local dated_backups_config="$DATED_BACKUPS"
            # Clean up the value - remove quotes and whitespace
            dated_backups_config=$(echo "$dated_backups_config" | tr -d '"\047' | tr '[:upper:]' '[:lower:]' | xargs)
            if [[ "$dated_backups_config" == "true" || "$dated_backups_config" == "1" || "$dated_backups_config" == "yes" || "$dated_backups_config" == "on" ]]; then
                dated_backups=true
                dated_backups_source="config"
            elif [[ "$dated_backups_config" == "false" || "$dated_backups_config" == "0" || "$dated_backups_config" == "no" || "$dated_backups_config" == "off" ]]; then
                dated_backups=false
                dated_backups_source="config"
            else
                log WARN "Invalid DATED_BACKUPS value in config: '$dated_backups_config'. Must be true/false. Using default: false"
                dated_backups=false
                dated_backups_source="default"
            fi
        fi
        
        # Handle folder_structure boolean config
        if [[ -z "$folder_structure" && -n "${FOLDER_STRUCTURE:-}" ]]; then
            local folder_structure_config="$FOLDER_STRUCTURE"
            # Clean up the value - remove quotes and whitespace
            folder_structure_config=$(echo "$folder_structure_config" | tr -d '"\047' | tr '[:upper:]' '[:lower:]' | xargs)
            if [[ "$folder_structure_config" == "true" || "$folder_structure_config" == "1" || "$folder_structure_config" == "yes" || "$folder_structure_config" == "on" ]]; then
                folder_structure=true
                folder_structure_source="config"
            elif [[ "$folder_structure_config" == "false" || "$folder_structure_config" == "0" || "$folder_structure_config" == "no" || "$folder_structure_config" == "off" ]]; then
                folder_structure=false
                folder_structure_source="config"
            else
                log WARN "Invalid FOLDER_STRUCTURE value in config: '$folder_structure_config'. Must be true/false. Using default: false"
                folder_structure=false
                folder_structure_source="default"
            fi
        fi
        
        # Handle verbose boolean config
        if [[ -z "$verbose" && -n "${VERBOSE:-}" ]]; then
            local verbose_config="$VERBOSE"
            # Clean up the value - remove quotes and whitespace
            verbose_config=$(echo "$verbose_config" | tr -d '"\047' | tr '[:upper:]' '[:lower:]' | xargs)
            if [[ "$verbose_config" == "true" || "$verbose_config" == "1" || "$verbose_config" == "yes" || "$verbose_config" == "on" ]]; then
                verbose=true
            elif [[ "$verbose_config" == "false" || "$verbose_config" == "0" || "$verbose_config" == "no" || "$verbose_config" == "off" ]]; then
                verbose=false
            else
                log WARN "Invalid VERBOSE value in config: '$verbose_config'. Must be true/false. Using default: false"
                verbose=false
            fi
        fi
        
        # Handle dry_run boolean config
        if [[ -z "$dry_run" && -n "${DRY_RUN:-}" ]]; then
            local dry_run_config="$DRY_RUN"
            # Clean up the value - remove quotes and whitespace
            dry_run_config=$(echo "$dry_run_config" | tr -d '"\047' | tr '[:upper:]' '[:lower:]' | xargs)
            if [[ "$dry_run_config" == "true" || "$dry_run_config" == "1" || "$dry_run_config" == "yes" || "$dry_run_config" == "on" ]]; then
                dry_run=true
                dry_run_source="config"
            elif [[ "$dry_run_config" == "false" || "$dry_run_config" == "0" || "$dry_run_config" == "no" || "$dry_run_config" == "off" ]]; then
                dry_run=false
                dry_run_source="config"
            else
                log WARN "Invalid DRY_RUN value in config: '$dry_run_config'. Must be true/false. Using default: false"
                dry_run=false
                dry_run_source="default"
            fi
        fi

        # Handle credentials_encrypted boolean config
        if [[ -z "$credentials_encrypted" && -n "${CREDENTIALS_ENCRYPTED:-}" ]]; then
            local credentials_encrypted_config="$CREDENTIALS_ENCRYPTED"
            credentials_encrypted_config=$(echo "$credentials_encrypted_config" | tr -d '"\047' | tr '[:upper:]' '[:lower:]' | xargs)
            if [[ "$credentials_encrypted_config" == "true" || "$credentials_encrypted_config" == "1" || "$credentials_encrypted_config" == "yes" || "$credentials_encrypted_config" == "on" ]]; then
                credentials_encrypted=true
                credentials_encrypted_source="config"
            elif [[ "$credentials_encrypted_config" == "false" || "$credentials_encrypted_config" == "0" || "$credentials_encrypted_config" == "no" || "$credentials_encrypted_config" == "off" ]]; then
                credentials_encrypted=false
                credentials_encrypted_source="config"
            else
                log WARN "Invalid CREDENTIALS_ENCRYPTED value in config: '$credentials_encrypted_config'. Must be true/false. Using default: true"
                credentials_encrypted=true
                credentials_encrypted_source="default"
            fi
        fi

        # Handle alternate credentials folder name for Git backups/restores
        if [[ -n "${CREDENTIALS_FOLDER_NAME:-}" ]]; then
            local credentials_folder_config="$CREDENTIALS_FOLDER_NAME"
            credentials_folder_config=$(echo "$credentials_folder_config" | tr -d '"\047' | xargs)
            credentials_folder_config="${credentials_folder_config%%/}"
            if [[ -z "$credentials_folder_config" ]]; then
                log WARN "CREDENTIALS_FOLDER_NAME in config is empty after normalization. Using default: .credentials"
                credentials_folder_name=".credentials"
            else
                credentials_folder_name="$credentials_folder_config"
                log DEBUG "Using configured credentials folder: $credentials_folder_name"
            fi
        fi
        
        # === PATH SETTINGS ===
        if [[ -z "$local_backup_path" && -n "${LOCAL_BACKUP_PATH:-}" ]]; then
            local_backup_path="$LOCAL_BACKUP_PATH"
            local_backup_path_source="config"
        fi
        
        if [[ -z "$local_rotation_limit" && -n "${LOCAL_ROTATION_LIMIT:-}" ]]; then
            local_rotation_limit="$LOCAL_ROTATION_LIMIT"
            local_rotation_limit_source="config"
        fi
        
        # === N8N API SETTINGS ===
        if [[ -z "$n8n_base_url" && -n "${N8N_BASE_URL:-}" ]]; then
            n8n_base_url="$N8N_BASE_URL"
        fi
        
        if [[ -z "$n8n_api_key" && -n "${N8N_API_KEY:-}" ]]; then
            n8n_api_key="$N8N_API_KEY"
        fi

        if [[ -z "$n8n_session_credential" ]]; then
            if [[ -n "${N8N_LOGIN_CREDENTIAL_NAME:-}" ]]; then
                n8n_session_credential="$N8N_LOGIN_CREDENTIAL_NAME"
            elif [[ -n "${N8N_LOGIN_CREDENTIAL_NAME_NAME:-}" ]]; then
                n8n_session_credential="$N8N_LOGIN_CREDENTIAL_NAME_NAME"
            fi
        fi

        if [[ -z "$git_commit_name" && -n "${GIT_COMMIT_NAME:-}" ]]; then
            git_commit_name="$GIT_COMMIT_NAME"
        fi

        if [[ -z "$git_commit_email" && -n "${GIT_COMMIT_EMAIL:-}" ]]; then
            git_commit_email="$GIT_COMMIT_EMAIL"
        fi

        # Backward compatibility: allow direct email/password configuration if still provided
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
        if [[ "$workflows_source" == "unset" ]]; then
            workflows_source="default"
        fi
    fi
    
    if [[ -z "$credentials" ]]; then
        credentials=1  # Default to local
        if [[ "$credentials_source" == "unset" ]]; then
            credentials_source="default"
        fi
    fi
    
    # Set path defaults
    if [[ -z "$local_backup_path" ]]; then
        local_backup_path="$HOME/n8n-backup"
        if [[ "$local_backup_path_source" == "unset" ]]; then
            local_backup_path_source="default"
        fi
    fi
    
    if [[ -z "$local_rotation_limit" ]]; then
        local_rotation_limit="10"
        if [[ "$local_rotation_limit_source" == "unset" ]]; then
            local_rotation_limit_source="default"
        fi
    fi
    
    # Set other defaults
    if [[ -z "$restore_type" ]]; then
        restore_type="all"
    fi
    
    if [[ -z "$github_branch" ]]; then
        github_branch="main"
    fi

    if [[ -z "$git_commit_name" ]]; then
        git_commit_name="N8N Backup Manager"
    fi

    if [[ -z "$git_commit_email" ]]; then
        local base_domain raw_domain
        raw_domain="${n8n_base_url:-}"
        if [[ -n "$raw_domain" ]]; then
            base_domain=$(echo "$raw_domain" | sed -E 's#^[a-zA-Z]+://##' | sed 's#/.*$##')
            base_domain="${base_domain%%:*}"
            base_domain=$(echo "$base_domain" | tr '[:upper:]' '[:lower:]')
            base_domain="${base_domain:-n8n.local}"
        else
            base_domain="n8n.local"
        fi
        git_commit_email="backup@${base_domain}"
    fi

    if [[ -z "$dated_backups" ]]; then
        dated_backups=false
        if [[ "$dated_backups_source" == "unset" ]]; then
            dated_backups_source="default"
        fi
    fi

    if [[ -z "$dry_run" ]]; then
        dry_run=false
        if [[ "$dry_run_source" == "unset" ]]; then
            dry_run_source="default"
        fi
    fi

    if [[ -z "$folder_structure" ]]; then
        folder_structure=false
        if [[ "$folder_structure_source" == "unset" ]]; then
            folder_structure_source="default"
        fi
    fi

    # Default to encrypted credential exports unless explicitly disabled
    if [[ -z "${credentials_encrypted:-}" ]]; then
        credentials_encrypted=true
        log DEBUG "Defaulting to encrypted credential exports: credentials_encrypted=true"
        if [[ "$credentials_encrypted_source" == "unset" ]]; then
            credentials_encrypted_source="default"
        fi
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

        local filtered_output=""
        if [ -n "$output" ]; then
            filtered_output=$(echo "$output" | grep -vE 'OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS|N8N_BLOCK_ENV_ACCESS_IN_NODE' || true)
        fi
        
        if [ "$verbose" = "true" ] && [ -n "$filtered_output" ]; then
            log DEBUG "Container output:\n$(echo "$filtered_output" | sed 's/^/  /')"
        fi
        
        if [ $exit_code -ne 0 ]; then
            log ERROR "Command failed in container (Exit Code: $exit_code): $cmd"
            if [ "$verbose" != "true" ] && [ -n "$filtered_output" ]; then
                log ERROR "Container output:\n$(echo "$filtered_output" | sed 's/^/  /')"
            fi
            return 1
        fi
        
        return 0
    fi
}

timestamp() {
    date "+%Y-%m-%d_%H-%M-%S"
}