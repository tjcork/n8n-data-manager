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
    if [ "$level" = "DEBUG" ] && [ "$ARG_VERBOSE" != "true" ]; then 
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
    if [ -n "$ARG_LOG_FILE" ]; then
        echo "$plain" >> "$ARG_LOG_FILE"
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
    local file_to_load="${ARG_CONFIG_FILE:-$CONFIG_FILE_PATH}"
    file_to_load="${file_to_load/#\~/$HOME}"

    if [ -f "$file_to_load" ]; then
        log INFO "Loading configuration from $file_to_load..."
        source <(grep -vE '^\s*(#|$)' "$file_to_load" 2>/dev/null || true)
        
        ARG_TOKEN=${ARG_TOKEN:-${CONF_GITHUB_TOKEN:-}}
        ARG_REPO=${ARG_REPO:-${CONF_GITHUB_REPO:-}}
        ARG_BRANCH=${ARG_BRANCH:-${CONF_GITHUB_BRANCH:-main}}
        ARG_CONTAINER=${ARG_CONTAINER:-${CONF_DEFAULT_CONTAINER:-}}
        DEFAULT_CONTAINER=${CONF_DEFAULT_CONTAINER:-}
        
        if ! $ARG_DATED_BACKUPS; then 
            CONF_DATED_BACKUPS_VAL=${CONF_DATED_BACKUPS:-false}
            if [[ "$CONF_DATED_BACKUPS_VAL" == "true" ]]; then ARG_DATED_BACKUPS=true; fi
        fi
        
        if [[ "$ARG_CREDENTIALS_STORAGE" == "local" ]]; then 
            CONF_CREDENTIALS_STORAGE_VAL=${CONF_CREDENTIALS_STORAGE:-"local"}
            if [[ "$CONF_CREDENTIALS_STORAGE_VAL" == "remote" ]]; then ARG_CREDENTIALS_STORAGE="remote"; fi
        fi
        
        # Load workflows storage from config if not specified
        if [[ -z "$ARG_WORKFLOWS_STORAGE" ]]; then
            ARG_WORKFLOWS_STORAGE=${CONF_WORKFLOWS_STORAGE:-}
        fi
        
        # Load local backup path from config if not specified  
        if [[ -z "$ARG_LOCAL_BACKUP_PATH" ]]; then
            ARG_LOCAL_BACKUP_PATH=${CONF_LOCAL_BACKUP_PATH:-}
        fi
        
        # Load rotation limit from config if not specified
        if [[ -z "$ARG_LOCAL_ROTATION_LIMIT" ]]; then
            ARG_LOCAL_ROTATION_LIMIT=${CONF_LOCAL_ROTATION_LIMIT:-}
        fi
        
        # Load folder structure options from config if not specified
        if ! $ARG_FOLDER_STRUCTURE; then
            CONF_FOLDER_STRUCTURE_VAL=${CONF_FOLDER_STRUCTURE:-false}
            if [[ "$CONF_FOLDER_STRUCTURE_VAL" == "true" ]]; then ARG_FOLDER_STRUCTURE=true; fi
        fi
        
        if [[ -z "$ARG_N8N_BASE_URL" ]]; then
            ARG_N8N_BASE_URL=${CONF_N8N_BASE_URL:-}
        fi
        
        if [[ -z "$ARG_N8N_API_KEY" ]]; then
            ARG_N8N_API_KEY=${CONF_N8N_API_KEY:-}
        fi
        
        ARG_RESTORE_TYPE=${ARG_RESTORE_TYPE:-${CONF_RESTORE_TYPE:-all}}
        
        if ! $ARG_VERBOSE; then
            CONF_VERBOSE_VAL=${CONF_VERBOSE:-false}
            if [[ "$CONF_VERBOSE_VAL" == "true" ]]; then ARG_VERBOSE=true; fi
        fi
        
        ARG_LOG_FILE=${ARG_LOG_FILE:-${CONF_LOG_FILE:-}}
        
    elif [ -n "$ARG_CONFIG_FILE" ]; then
        log WARN "Configuration file specified but not found: $file_to_load"
    fi
    
    if [ -n "$ARG_LOG_FILE" ] && [[ "$ARG_LOG_FILE" != /* ]]; then
        log WARN "Log file path '$ARG_LOG_FILE' is not absolute. Prepending current directory."
        ARG_LOG_FILE="$(pwd)/$ARG_LOG_FILE"
    fi
    
    if [ -n "$ARG_LOG_FILE" ]; then
        log DEBUG "Ensuring log file exists and is writable: $ARG_LOG_FILE"
        mkdir -p "$(dirname "$ARG_LOG_FILE")" || { log ERROR "Could not create directory for log file: $(dirname "$ARG_LOG_FILE")"; exit 1; }
        touch "$ARG_LOG_FILE" || { log ERROR "Log file is not writable: $ARG_LOG_FILE"; exit 1; }
        log INFO "Logging output also to: $ARG_LOG_FILE"
    fi
    
    # Validate folder structure configuration
    if $ARG_FOLDER_STRUCTURE; then
        if [[ -z "$ARG_N8N_BASE_URL" ]]; then
            log ERROR "Folder structure enabled but n8n URL not provided. Set CONF_N8N_BASE_URL or use --n8n-url"
            exit 1
        fi
        if [[ -z "$ARG_N8N_API_KEY" ]]; then
            log ERROR "Folder structure enabled but n8n API key not provided. Set CONF_N8N_API_KEY or use --n8n-api-key"
            exit 1
        fi
        log INFO "Folder structure mirroring enabled with n8n instance: $ARG_N8N_BASE_URL"
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
    shift
    docker exec "$container_id" "$@"
}

timestamp() {
    date "+%Y-%m-%d_%H-%M-%S"
}