#!/usr/bin/env bash
# =========================================================
# n8n-manager.sh - Interactive backup/restore for n8n
# =========================================================
# Flexible Backup System:
# - Workflows: local files or Git repository (user choice)
#   * Git: Individual workflow files in n8n folder structure
#   * Local: Single JSON file for easy management
# - Credentials: local files or Git repository (user choice)
# - Local storage with proper permissions (chmod 600)
# - Archive rotation for local backups (5-10 backups)
# - .gitignore management for Git repositories
# - Version control: [New]/[Updated]/[Deleted] commit messages
# - Folder mirroring: Git structure matches n8n interface
# =========================================================
set -Eeuo pipefail
IFS=$'\n\t'

# --- Configuration ---
CONFIG_FILE_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/n8n-manager/config"

# --- Global variables ---
VERSION="4.0.0"
DEBUG_TRACE=${DEBUG_TRACE:-false} # Set to true for trace debugging
SELECTED_ACTION=""
SELECTED_CONTAINER_ID=""
GITHUB_TOKEN=""
GITHUB_REPO=""
GITHUB_BRANCH="main"
DEFAULT_CONTAINER=""
SELECTED_RESTORE_TYPE="all"
# Flags/Options
ARG_ACTION=""
ARG_CONTAINER=""
ARG_TOKEN=""
ARG_REPO=""
ARG_BRANCH=""
ARG_CONFIG_FILE=""
ARG_DATED_BACKUPS=false
ARG_WORKFLOWS_STORAGE=""  # Where to store workflows: "local", "remote", or "" (not specified)
ARG_CREDENTIALS_STORAGE=""  # Where to store credentials: "local", "remote", or "" (not specified)
ARG_LOCAL_BACKUP_PATH=""  # Custom local backup path (defaults to ~/n8n-backup)
ARG_LOCAL_ROTATION_LIMIT=""  # Local backup rotation limit (0=overwrite, number=keep N most recent, empty=unlimited)
ARG_RESTORE_TYPE="all"  # Keep for backwards compatibility
ARG_DRY_RUN=false
ARG_VERBOSE=false
ARG_LOG_FILE=""
ARG_FOLDER_STRUCTURE=false
ARG_N8N_BASE_URL=""
ARG_N8N_API_KEY=""
CONF_LOCAL_ROTATION_LIMIT=""  # Default rotation limit for local backups
CONF_DATED_BACKUPS=false
CONF_VERBOSE=false
CONF_LOG_FILE=""
CONF_FOLDER_STRUCTURE=false
CONF_N8N_BASE_URL=""
CONF_N8N_API_KEY=""

# ANSI colors for better UI (using printf for robustness)
printf -v RED     '\033[0;31m'
printf -v GREEN   '\033[0;32m'
printf -v BLUE    '\033[0;34m'
printf -v YELLOW  '\033[1;33m'
printf -v NC      '\033[0m' # No Color
printf -v BOLD    '\033[1m'
printf -v DIM     '\033[2m'

# --- Logging Functions ---

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

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Automated backup and restore tool for n8n Docker containers using GitHub.
Reads configuration from ${CONFIG_FILE_PATH} if it exists.

Options:
  --action <action>     Action to perform: 'backup' or 'restore'.
  --container <id|name> Target Docker container ID or name.
  --token <pat>         GitHub Personal Access Token (PAT).
  --repo <user/repo>    GitHub repository (e.g., 'myuser/n8n-backup').
  --branch <branch>     GitHub branch to use (defaults to 'main').
  --dated               Create timestamped subdirectory for backups (e.g., YYYY-MM-DD_HH-MM-SS/).
  --workflows [mode]    Include workflows in backup. Mode: 'local' (default) or 'remote' (Git repo).
  --credentials [mode]  Include credentials in backup. Mode: 'local' (default) or 'remote' (Git repo).
  --path <path>         Local backup directory path (defaults to '~/n8n-backup').
  --rotation <limit>    Local backup rotation: '0' (overwrite), number (keep N most recent), 'unlimited' (keep all).
  --folder-structure    Enable n8n folder structure mirroring in Git (requires API access).
  --n8n-url <url>       n8n instance URL (e.g., 'http://localhost:5678').
  --n8n-api-key <key>   n8n API key for folder structure access.
  --restore-type <type> Type of restore: 'all' (default), 'workflows', or 'credentials' (legacy).
                        Overrides CONF_RESTORE_TYPE in config file.
  --dry-run             Simulate the action without making any changes.
  --verbose             Enable detailed debug logging.
  --log-file <path>     Path to a file to append logs to.
  --config <path>       Path to a custom configuration file.
  -h, --help            Show this help message and exit.

Configuration File (${CONFIG_FILE_PATH}):
  Define variables like:
    CONF_GITHUB_TOKEN="ghp_..."
    CONF_GITHUB_REPO="user/repo"
    CONF_GITHUB_BRANCH="main"
    CONF_DEFAULT_CONTAINER="n8n-container-name"
    CONF_DATED_BACKUPS=true # Optional, defaults to false
    CONF_WORKFLOWS_STORAGE="local" # Optional: "local" or "remote" (Git repo)
    CONF_CREDENTIALS_STORAGE="local" # Optional: "local" (default, secure) or "remote" (Git repo)
    CONF_LOCAL_BACKUP_PATH="/custom/backup/path" # Optional, defaults to ~/n8n-backup
    CONF_LOCAL_ROTATION_LIMIT="10" # Optional: 0 (overwrite), number (keep N), "unlimited" (keep all)
    CONF_FOLDER_STRUCTURE=false # Optional: Enable n8n folder structure mirroring
    CONF_N8N_BASE_URL="http://localhost:5678" # Required if CONF_FOLDER_STRUCTURE=true
    CONF_N8N_API_KEY="n8n_api_..." # Required if CONF_FOLDER_STRUCTURE=true
    CONF_RESTORE_TYPE="all" # Optional, defaults to 'all' (legacy compatibility)
    CONF_VERBOSE=false      # Optional, defaults to false
    CONF_LOG_FILE="/var/log/n8n-manager.log" # Optional

Command-line arguments override configuration file settings.
For non-interactive use, required parameters (action, container, token, repo)
can be provided via arguments or the configuration file.
EOF
}

select_container() {
    log HEADER "Selecting n8n container..."
    mapfile -t containers < <(docker ps --format "{{.ID}}\t{{.Names}}\t{{.Image}}" 2>/dev/null || true)

    if [ ${#containers[@]} -eq 0 ]; then
        log ERROR "No running Docker containers found."
        exit 1
    fi

    local n8n_options=()
    local other_options=()
    local all_ids=()
    local default_option_num=-1

    log INFO "${BOLD}Available running containers:${NC}"
    log INFO "${DIM}------------------------------------------------${NC}"
    log INFO "${BOLD}Num\tID (Short)\tName\tImage${NC}"
    log INFO "${DIM}------------------------------------------------${NC}"

    local i=1
    for container_info in "${containers[@]}"; do
        local id name image
        IFS=$'\t' read -r id name image <<< "$container_info"
        local short_id=${id:0:12}
        all_ids+=("$id")
        local display_name="$name"
        local is_default=false

        if [ -n "$DEFAULT_CONTAINER" ] && { [ "$id" = "$DEFAULT_CONTAINER" ] || [ "$name" = "$DEFAULT_CONTAINER" ]; }; then
            is_default=true
            default_option_num=$i
            display_name="${display_name} ${YELLOW}(default)${NC}"
        fi

        local line
        if [[ "$image" == *"n8nio/n8n"* || "$name" == *"n8n"* ]]; then
            line=$(printf "%s%d)%s %s\t%s\t%s %s(n8n)%s" "$GREEN" "$i" "$NC" "$short_id" "$display_name" "$image" "$YELLOW" "$NC")
            n8n_options+=("$line")
        else
            line=$(printf "%d) %s\t%s\t%s" "$i" "$short_id" "$display_name" "$image")
            other_options+=("$line")
        fi
        i=$((i+1))
    done

    for option in "${n8n_options[@]}"; do echo -e "$option"; done
    for option in "${other_options[@]}"; do echo -e "$option"; done
    echo -e "${DIM}------------------------------------------------${NC}"

    local selection
    local prompt_text="Select container number"
    if [ "$default_option_num" -ne -1 ]; then
        prompt_text="$prompt_text [default: $default_option_num]"
    fi
    prompt_text+=": "

    while true; do
        printf "$prompt_text"
        read -r selection
        selection=${selection:-$default_option_num}

        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#containers[@]} ]; then
            local selected_full_id="${all_ids[$((selection-1))]}"
            log SUCCESS "Selected container: $selected_full_id"
            SELECTED_CONTAINER_ID="$selected_full_id"
            return
        elif [ -z "$selection" ] && [ "$default_option_num" -ne -1 ]; then
             local selected_full_id="${all_ids[$((default_option_num-1))]}"
             log SUCCESS "Selected container (default): $selected_full_id"
             SELECTED_CONTAINER_ID="$selected_full_id"
             return
        else
            log ERROR "Invalid selection. Please enter a number between 1 and ${#containers[@]}."
        fi
    done
}

select_action() {
    log HEADER "Choose Action"
    echo "1) Backup n8n - Local or to GitHub"
    echo "2) Restore n8n - Local or from GitHub"
    echo "3) Quit"

    local choice
    while true; do
        printf "\nSelect an option (1-3): "
        read -r choice
        case "$choice" in
            1) SELECTED_ACTION="backup"; return ;; 
            2) SELECTED_ACTION="restore"; return ;; 
            3) log INFO "Exiting..."; exit 0 ;; 
            *) log ERROR "Invalid option. Please select 1, 2, or 3." ;; 
        esac
    done
}

select_restore_type() {
    log HEADER "Choose Restore Type"
    
    # Check credential availability for better UX
    local local_backup_dir="$HOME/n8n-backup"
    local local_credentials_file="$local_backup_dir/credentials.json"
    local has_local_creds=false
    local has_git_creds=false
    
    if [ -f "$local_credentials_file" ] && [ -s "$local_credentials_file" ]; then
        has_local_creds=true
    fi
    
    # Note: We can't check Git credentials here since we haven't downloaded the repo yet
    # This will be handled during the restore process
    
    echo "1) All (Workflows & Credentials)"
    if $has_local_creds; then
        echo "   📄 Workflows from Git repository + 🔒 Credentials from local secure storage"
    else
        echo "   📄 Workflows from Git repository + 🔒 Credentials from available source"
    fi
    echo "2) Workflows Only"
    echo "   📄 Workflows from Git repository (credentials unchanged)"
    echo "3) Credentials Only"
    if $has_local_creds; then
        echo "   🔒 Credentials from local secure storage (workflows unchanged)"
    else
        echo "   🔒 Credentials from available source (workflows unchanged)"
    fi

    local choice
    while true; do
        printf "\nSelect an option (1-3) [default: 1]: "
        read -r choice
        choice=${choice:-1}
        case "$choice" in
            1) SELECTED_RESTORE_TYPE="all"; return ;; 
            2) SELECTED_RESTORE_TYPE="workflows"; return ;; 
            3) SELECTED_RESTORE_TYPE="credentials"; return ;; 
            *) log ERROR "Invalid option. Please select 1, 2, or 3." ;; 
        esac
    done
}

select_credential_source() {
    local local_file="$1"
    local git_file="$2"
    local selected_source=""
    
    log HEADER "Multiple Credential Sources Found"
    log INFO "Both local and Git repository credentials are available."
    echo "1) Local Secure Storage (Recommended)"
    echo "   📍 $local_file"
    echo "   🔒 Stored securely with proper file permissions"
    echo "2) Git Repository (Legacy)"
    echo "   📍 $git_file"
    echo "   ⚠️  Less secure - credentials stored in Git history"
    
    local choice
    while true; do
        printf "\nSelect credential source (1-2) [default: 1]: "
        read -r choice
        choice=${choice:-1}
        case "$choice" in
            1) selected_source="$local_file"; break ;;
            2) 
                log WARN "⚠️  You selected Git repository credentials (less secure)"
                printf "Are you sure? (yes/no) [no]: "
                local confirm
                read -r confirm
                if [[ "$confirm" == "yes" || "$confirm" == "y" ]]; then
                    selected_source="$git_file"
                    break
                fi
                ;;
            *) log ERROR "Invalid option. Please select 1 or 2." ;;
        esac
    done
    
    echo "$selected_source"
}

show_restore_plan() {
    local restore_type="$1"
    local github_repo="$2"
    local branch="$3"
    
    log HEADER "📋 Restore Plan"
    log INFO "Repository: $github_repo (branch: $branch)"
    
    case "$restore_type" in
        "all")
            log INFO "📄 Workflows: Will be restored from Git repository"
            log INFO "🔒 Credentials: Will be restored from available source (local preferred)"
            log WARN "⚠️  This will REPLACE your current workflows and credentials"
            ;;
        "workflows")
            log INFO "📄 Workflows: Will be restored from Git repository"
            log INFO "🔒 Credentials: Will remain unchanged"
            log WARN "⚠️  This will REPLACE your current workflows only"
            ;;
        "credentials")
            log INFO "📄 Workflows: Will remain unchanged"
            log INFO "🔒 Credentials: Will be restored from available source (local preferred)"
            log WARN "⚠️  This will REPLACE your current credentials only"
            ;;
    esac
    
    return 0
}

get_github_config() {
    local local_token="$ARG_TOKEN"
    local local_repo="$ARG_REPO"
    local local_branch="$ARG_BRANCH"

    log HEADER "GitHub Configuration"

    while [ -z "$local_token" ]; do
        printf "Enter GitHub Personal Access Token (PAT): "
        read -s local_token
        echo
        if [ -z "$local_token" ]; then log ERROR "GitHub token is required."; fi
    done

    while [ -z "$local_repo" ]; do
        printf "Enter GitHub repository (format: username/repo): "
        read -r local_repo
        if [ -z "$local_repo" ] || ! echo "$local_repo" | grep -q "/"; then
            log ERROR "Invalid GitHub repository format. It should be 'username/repo'."
            local_repo=""
        fi
    done

    if [ -z "$local_branch" ]; then
         printf "Enter Branch to use [main]: "
         read -r local_branch
         local_branch=${local_branch:-main}
    else
        log INFO "Using branch: $local_branch"
    fi

    GITHUB_TOKEN="$local_token"
    GITHUB_REPO="$local_repo"
    GITHUB_BRANCH="$local_branch"
}

# Archive credentials with rotation (keep 5-10 backups)
archive_credentials() {
    local source_file="$1"
    local backup_dir="$2"
    local is_dry_run="$3"
    local rotation_limit=${4:-10}  # 0=overwrite, number=keep N, unlimited=keep all

    if [ ! -f "$source_file" ]; then
        log WARN "Source credentials file not found: $source_file"
        return 1
    fi

    # Handle different rotation modes
    if [[ "$rotation_limit" == "0" ]]; then
        # Mode 0: Just overwrite, no archiving
        log DEBUG "Rotation disabled - credentials will be overwritten"
        return 0
    fi

    local archive_dir="$backup_dir/archive"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local archive_file="$archive_dir/credentials_${timestamp}.json"

    if $is_dry_run; then
        log DRYRUN "Would create archive directory: $archive_dir"
        log DRYRUN "Would archive credentials to: $archive_file"
        if [[ "$rotation_limit" == "unlimited" ]]; then
            log DRYRUN "Would keep unlimited credential archives"
        else
            log DRYRUN "Would rotate archives to keep max $rotation_limit files"
        fi
        return 0
    fi

    # Create archive directory
    if ! mkdir -p "$archive_dir"; then
        log ERROR "Failed to create archive directory: $archive_dir"
        return 1
    fi
    chmod 700 "$archive_dir" || log WARN "Could not set permissions on archive directory"

    # Archive current credentials
    if ! cp "$source_file" "$archive_file"; then
        log ERROR "Failed to archive credentials"
        return 1
    fi
    chmod 600 "$archive_file" || log WARN "Could not set permissions on archived credentials"
    log SUCCESS "Credentials archived to: $archive_file"

    # Handle rotation based on limit
    if [[ "$rotation_limit" == "unlimited" ]]; then
        log DEBUG "Unlimited rotation - keeping all credential archives"
    elif [[ "$rotation_limit" =~ ^[0-9]+$ ]] && [ "$rotation_limit" -gt 0 ]; then
        # Rotate archives - keep only the most recent N
        local archive_count
        archive_count=$(find "$archive_dir" -name "credentials_*.json" | wc -l)
        if [ "$archive_count" -gt "$rotation_limit" ]; then
            local files_to_remove=$((archive_count - rotation_limit))
            log INFO "Rotating credential archives - removing $files_to_remove old files (keeping $rotation_limit most recent)"
            
            # Remove oldest files (sort by name, which includes timestamp)
            find "$archive_dir" -name "credentials_*.json" | sort | head -n "$files_to_remove" | while read -r old_file; do
                rm -f "$old_file"
                log DEBUG "Removed old archive: $(basename "$old_file")"
            done
        fi
        log INFO "Credential archive rotation complete (keeping $rotation_limit most recent)"
    fi

    return 0
}

# Archive workflows with configurable rotation
archive_workflows() {
    local source_file="$1"
    local backup_dir="$2"
    local is_dry_run="$3"
    local rotation_limit=${4:-10}  # 0=overwrite, number=keep N, unlimited=keep all

    if [ ! -f "$source_file" ]; then
        log WARN "Source workflows file not found: $source_file"
        return 1
    fi

    # Handle different rotation modes
    if [[ "$rotation_limit" == "0" ]]; then
        # Mode 0: Just overwrite, no archiving
        log DEBUG "Rotation disabled - workflows will be overwritten"
        return 0
    fi

    local archive_dir="$backup_dir/archive"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local archive_file="$archive_dir/workflows_${timestamp}.json"

    if $is_dry_run; then
        log DRYRUN "Would create archive directory: $archive_dir"
        log DRYRUN "Would archive workflows to: $archive_file"
        log DRYRUN "Would rotate archives to keep max $max_archives files"
        return 0
    fi

    # Create archive directory
    if ! mkdir -p "$archive_dir"; then
        log ERROR "Failed to create archive directory: $archive_dir"
        return 1
    fi
    chmod 700 "$archive_dir" || log WARN "Could not set permissions on archive directory"

    # Archive current workflows
    if ! cp "$source_file" "$archive_file"; then
        log ERROR "Failed to archive workflows"
        return 1
    fi
    chmod 600 "$archive_file" || log WARN "Could not set permissions on archived workflows"
    log SUCCESS "Workflows archived to: $archive_file"

    # Handle rotation based on limit
    if [[ "$rotation_limit" == "unlimited" ]]; then
        log DEBUG "Unlimited rotation - keeping all workflow archives"
    elif [[ "$rotation_limit" =~ ^[0-9]+$ ]] && [ "$rotation_limit" -gt 0 ]; then
        # Rotate archives - keep only the most recent N
        local archive_count
        archive_count=$(find "$archive_dir" -name "workflows_*.json" | wc -l)
        if [ "$archive_count" -gt "$rotation_limit" ]; then
            local files_to_remove=$((archive_count - rotation_limit))
            log INFO "Rotating workflow archives - removing $files_to_remove old files (keeping $rotation_limit most recent)"
            
            # Remove oldest files (sort by name, which includes timestamp)
            find "$archive_dir" -name "workflows_*.json" | sort | head -n "$files_to_remove" | while read -r old_file; do
                rm -f "$old_file"
                log DEBUG "Removed old archive: $(basename "$old_file")"
            done
        fi
        log INFO "Workflow archive rotation complete (keeping $rotation_limit most recent)"
    fi
    return 0
}

rotate_local_timestamped_backups() {
    local base_backup_dir="$1"
    local rotation_limit=${2:-10}  # 0=overwrite, number=keep N, unlimited=keep all
    local is_dry_run="$3"

    if [ ! -d "$base_backup_dir" ]; then
        log WARN "Base backup directory not found: $base_backup_dir"
        return 1
    fi

    # Handle different rotation modes
    if [[ "$rotation_limit" == "0" ]]; then
        log DEBUG "Rotation disabled for timestamped directories - they accumulate until manually cleaned"
        return 0
    elif [[ "$rotation_limit" == "unlimited" ]]; then
        log DEBUG "Unlimited rotation - keeping all timestamped backup directories"
        return 0
    elif ! [[ "$rotation_limit" =~ ^[0-9]+$ ]]; then
        log WARN "Invalid rotation limit: $rotation_limit - defaulting to 10"
        rotation_limit=10
    fi

    # Find timestamped directories (format: YYYY-MM-DD_HH-MM-SS)
    local timestamped_dirs=()
    while IFS= read -r -d '' dir; do
        timestamped_dirs+=("$dir")
    done < <(find "$base_backup_dir" -maxdepth 1 -type d -name "*-*-*_*-*-*" -print0 | sort -z)

    local backup_count=${#timestamped_dirs[@]}
    if [ "$backup_count" -gt "$rotation_limit" ]; then
        local dirs_to_remove=$((backup_count - rotation_limit))
        log INFO "Rotating local timestamped backups - removing $dirs_to_remove old directories (keeping $rotation_limit most recent)"
        
        if $is_dry_run; then
            for ((i=0; i<dirs_to_remove; i++)); do
                log DRYRUN "Would remove old backup directory: $(basename "${timestamped_dirs[$i]}")"
            done
        else
            # Remove oldest directories
            for ((i=0; i<dirs_to_remove; i++)); do
                rm -rf "${timestamped_dirs[$i]}"
                log DEBUG "Removed old backup directory: $(basename "${timestamped_dirs[$i]}")"
            done
        fi
    else
        log DEBUG "Local backup rotation: keeping all $backup_count directories (under limit of $rotation_limit)"
    fi

    return 0
}

check_github_access() {
    local token="$1"
    local repo="$2"
    local branch="$3"
    local action_type="$4" # 'backup' or 'restore'
    local check_branch_exists=false
    if [[ "$action_type" == "restore" ]]; then
        check_branch_exists=true
    fi

    log HEADER "Checking GitHub Access & Repository Status..."

    # 1. Check Token and Scopes
    log INFO "Verifying GitHub token and permissions..."
    local scopes
    scopes=$(curl -s -I -H "Authorization: token $token" https://api.github.com/user | grep -i '^x-oauth-scopes:' | sed 's/x-oauth-scopes: //i' | tr -d '\r')
    local http_status
    http_status=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token $token" https://api.github.com/user)

    log DEBUG "Token check HTTP status: $http_status"
    log DEBUG "Detected scopes: $scopes"

    if [[ "$http_status" -ne 200 ]]; then
        log ERROR "GitHub token is invalid or expired (HTTP Status: $http_status)."
        return 1
    fi

    # Check for either classic token (repo scope) or fine-grained token (contents scope)
    local has_required_scope=false
    if [ -n "$scopes" ]; then
        # Classic token with x-oauth-scopes header
        if echo "$scopes" | grep -qE '(^|,) *repo(,|$)'; then
            log SUCCESS "GitHub token is valid and has 'repo' scope (classic token)."
            has_required_scope=true
        elif echo "$scopes" | grep -qE '(^|,) *contents(,|$)'; then
            log SUCCESS "GitHub token is valid and has 'contents' scope (fine-grained token)."
            has_required_scope=true
        fi
    else
        # Fine-grained tokens may not have x-oauth-scopes header, so we test repository access directly
        log DEBUG "No x-oauth-scopes header found - testing repository access for fine-grained token..."
        local test_status
        test_status=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token $token" "https://api.github.com/repos/$repo")
        if [[ "$test_status" -eq 200 ]]; then
            log SUCCESS "GitHub token is valid and has repository access (fine-grained token)."
            has_required_scope=true
        fi
    fi

    if ! $has_required_scope; then
        log ERROR "GitHub token is missing required permissions."
        log INFO "For classic tokens: Please create a new token with the 'repo' scope selected."
        log INFO "For fine-grained tokens: Please ensure the token has 'Contents' repository permissions (read/write)."
        return 1
    fi

    # 2. Check Repository Existence
    log INFO "Verifying repository existence: $repo ..."
    http_status=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token $token" "https://api.github.com/repos/$repo")
    log DEBUG "Repo check HTTP status: $http_status"

    if [[ "$http_status" -ne 200 ]]; then
        log ERROR "Repository '$repo' not found or access denied (HTTP Status: $http_status)."
        log INFO "Please check the repository name and ensure the token has access."
        return 1
    fi
    log SUCCESS "Repository '$repo' found and accessible."

    # 3. Check Branch Existence (only if needed)
    if $check_branch_exists; then
        log INFO "Verifying branch existence: $branch ..."
        http_status=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: token $token" "https://api.github.com/repos/$repo/branches/$branch")
        log DEBUG "Branch check HTTP status: $http_status"

        if [[ "$http_status" -ne 200 ]]; then
            log ERROR "Branch '$branch' not found in repository '$repo' (HTTP Status: $http_status)."
            log INFO "Please check the branch name."
            return 1
        fi
        log SUCCESS "Branch '$branch' found in repository '$repo'."
    fi

    log SUCCESS "GitHub access checks passed."
    return 0
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
        if [ "$ARG_VERBOSE" = "true" ] && [ -n "$output" ]; then
            log DEBUG "Container output:\n$(echo "$output" | sed 's/^/  /')"
        fi
        
        if [ $exit_code -ne 0 ]; then
            log ERROR "Command failed in container (Exit Code: $exit_code): $cmd"
            if [ "$ARG_VERBOSE" != "true" ] && [ -n "$output" ]; then
                log ERROR "Container output:\n$(echo "$output" | sed 's/^/  /')"
            fi
            return 1
        fi
        
        return 0
    fi
}

timestamp() {
    date +"%Y-%m-%d_%H-%M-%S"
}

# --- n8n REST API Helper Functions ---

# Test connection to n8n instance and validate API key
test_n8n_api_connection() {
    local base_url="$1"
    local api_key="$2"
    
    log INFO "Testing n8n API connection to: $base_url"
    
    # Clean up URL (remove trailing slash)
    base_url="${base_url%/}"
    
    # Test API connection with basic endpoint
    local response
    local http_status
    if ! response=$(curl -s -w "\\n%{http_code}" -H "X-N8N-API-KEY: $api_key" "$base_url/rest/workflows?limit=1" 2>/dev/null); then
        log ERROR "Failed to connect to n8n API at: $base_url"
        return 1
    fi
    
    http_status=$(echo "$response" | tail -n1)
    local response_body=$(echo "$response" | head -n -1)
    
    if [[ "$http_status" == "401" ]]; then
        log ERROR "n8n API authentication failed. Please check your API key."
        return 1
    elif [[ "$http_status" == "404" ]]; then
        log ERROR "n8n API endpoint not found. Please check the URL and ensure n8n version supports REST API."
        return 1
    elif [[ "$http_status" != "200" ]]; then
        log ERROR "n8n API connection failed with HTTP status: $http_status"
        log DEBUG "Response body: $response_body"
        return 1
    fi
    
    log SUCCESS "n8n API connection successful!"
    return 0
}

# Fetch all projects from n8n instance
fetch_n8n_projects() {
    local base_url="$1"
    local api_key="$2"
    
    log DEBUG "Fetching projects from n8n API..."
    
    # Clean up URL
    base_url="${base_url%/}"
    
    local response
    local http_status
    if ! response=$(curl -s -w "\\n%{http_code}" -H "X-N8N-API-KEY: $api_key" "$base_url/rest/projects" 2>/dev/null); then
        log ERROR "Failed to fetch projects from n8n API"
        return 1
    fi
    
    http_status=$(echo "$response" | tail -n1)
    local response_body=$(echo "$response" | head -n -1)
    
    if [[ "$http_status" != "200" ]]; then
        log ERROR "Failed to fetch projects (HTTP $http_status)"
        return 1
    fi
    
    echo "$response_body"
    return 0
}

# Fetch folders for a specific project
fetch_project_folders() {
    local base_url="$1"
    local api_key="$2"
    local project_id="$3"
    
    log DEBUG "Fetching folders for project: $project_id"
    
    # Clean up URL
    base_url="${base_url%/}"
    
    local response
    local http_status
    if ! response=$(curl -s -w "\\n%{http_code}" -H "X-N8N-API-KEY: $api_key" "$base_url/rest/projects/$project_id/folders" 2>/dev/null); then
        log ERROR "Failed to fetch folders for project: $project_id"
        return 1
    fi
    
    http_status=$(echo "$response" | tail -n1)
    local response_body=$(echo "$response" | head -n -1)
    
    if [[ "$http_status" != "200" ]]; then
        log ERROR "Failed to fetch project folders (HTTP $http_status)"
        return 1
    fi
    
    echo "$response_body"
    return 0
}

# Fetch workflows with folder information
fetch_workflows_with_folders() {
    local base_url="$1"
    local api_key="$2"
    local project_id="${3:-}"  # Optional project filter
    
    log DEBUG "Fetching workflows with folder information..."
    
    # Clean up URL  
    base_url="${base_url%/}"
    
    local url="$base_url/rest/workflows?includeFolders=true"
    if [[ -n "$project_id" ]]; then
        url="$url&filter[projectId]=$project_id"
    fi
    
    local response
    local http_status
    if ! response=$(curl -s -w "\\n%{http_code}" -H "X-N8N-API-KEY: $api_key" "$url" 2>/dev/null); then
        log ERROR "Failed to fetch workflows with folders"
        return 1
    fi
    
    http_status=$(echo "$response" | tail -n1)
    local response_body=$(echo "$response" | head -n -1)
    
    if [[ "$http_status" != "200" ]]; then
        log ERROR "Failed to fetch workflows (HTTP $http_status)"
        return 1
    fi
    
    echo "$response_body"
    return 0
}

# Build folder structure based on n8n's actual folder hierarchy (replaces tag-based logic)
create_n8n_folder_structure() {
    local container_id="$1"
    local workflows_dir="$2"
    local target_dir="$3"
    local is_dry_run="$4"
    local base_url="$5"
    local api_key="$6"
    
    log INFO "Creating folder structure based on n8n's actual folders (not tags)..."
    
    # Test API connection first
    if ! test_n8n_api_connection "$base_url" "$api_key"; then
        log ERROR "Cannot proceed with folder structure creation - API connection failed"
        return 1
    fi
    
    # Get list of workflow files from container first
    local workflow_files
    if ! workflow_files=$(docker exec "$container_id" find "$workflows_dir" -name "*.json" -type f 2>/dev/null); then
        log ERROR "Failed to get workflow files from container"
        return 1
    fi
    
    if [[ -z "$workflow_files" ]]; then
        log INFO "No workflow files found - clean installation"
        return 0
    fi
    
    # Fetch projects and workflows with folder information from API
    local projects_response
    if ! projects_response=$(fetch_n8n_projects "$base_url" "$api_key"); then
        log ERROR "Failed to fetch projects from n8n API"
        return 1
    fi
    
    local workflows_response  
    if ! workflows_response=$(fetch_workflows_with_folders "$base_url" "$api_key"); then
        log ERROR "Failed to fetch workflows with folder information"
        return 1
    fi
    
    # Parse projects to create project name mapping
    local project_mapping
    project_mapping=$(echo "$projects_response" | python3 -c "
import json
import sys
try:
    data = json.load(sys.stdin)
    for project in data.get('data', data if isinstance(data, list) else []):
        project_id = project.get('id', '')
        project_name = project.get('name', 'Unknown')
        project_type = project.get('type', 'team')
        # Create clean project folder name
        if project_type == 'personal':
            folder_name = 'Personal'
        else:
            # Sanitize project name for folder use
            folder_name = project_name.replace('/', '_').replace(' ', '_')
        print(f'{project_id}|{folder_name}')
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)
    
    if [[ -z "$project_mapping" ]]; then
        log WARN "No project mapping found, using fallback structure"
        project_mapping="default|Personal"
    fi
    
    # Track existing workflows for deletion detection
    local existing_workflows=()
    if [[ -d "$target_dir" ]]; then
        while IFS= read -r -d '' existing_file; do
            if [[ "$existing_file" =~ ([0-9]+)\.json$ ]]; then
                existing_workflows+=("${BASH_REMATCH[1]}")
            fi
        done < <(find "$target_dir" -name "*.json" -type f -print0 2>/dev/null || true)
    fi
    
    local current_workflows=()
    local new_count=0
    local updated_count=0
    
    # Process each workflow file
    while IFS= read -r workflow_file; do
        if [[ -z "$workflow_file" ]]; then continue; fi
        
        # Copy workflow file to temporary location for processing
        local temp_workflow="/tmp/temp_workflow.json"
        if ! docker cp "${container_id}:${workflow_file}" "$temp_workflow" 2>/dev/null; then
            log WARN "Failed to copy workflow file: $workflow_file"
            continue
        fi
        
        # Extract basic workflow information
        local workflow_info
        if ! workflow_info=$(python3 -c "
import json
import sys
try:
    with open('$temp_workflow', 'r') as f:
        data = json.load(f)
    workflow_id = data.get('id', 'unknown')
    workflow_name = data.get('name', 'Unnamed Workflow')
    print(f'{workflow_id}|{workflow_name}')
except Exception as e:
    print('ERROR|ERROR')
    sys.exit(1)
" 2>/dev/null); then
            log WARN "Failed to parse workflow file: $workflow_file"
            rm -f "$temp_workflow"
            continue
        fi
        
        IFS='|' read -r workflow_id workflow_name <<< "$workflow_info"
        
        if [[ "$workflow_id" == "ERROR" ]]; then
            log WARN "Failed to extract workflow info from: $workflow_file"
            rm -f "$temp_workflow"
            continue
        fi
        
        current_workflows+=("$workflow_id")
        
        # Find workflow's project and folder information from API response
        local folder_info
        folder_info=$(echo "$workflows_response" | python3 -c "
import json
import sys
try:
    data = json.load(sys.stdin)
    workflows = data.get('data', data if isinstance(data, list) else [])
    for workflow in workflows:
        if workflow.get('id') == '$workflow_id':
            project_id = workflow.get('projectId', 'default')
            folder_id = workflow.get('folderId', None)
            folder_name = workflow.get('folderName', None)
            print(f'{project_id}|{folder_id or \"\"}|{folder_name or \"\"}')
            break
    else:
        # Workflow not found in API response, use default
        print('default||')
except Exception as e:
    print('default||')
" 2>/dev/null)
        
        if [[ -z "$folder_info" ]]; then
            folder_info="default||"
        fi
        
        IFS='|' read -r project_id folder_id folder_name <<< "$folder_info"
        
        # Determine project folder name from mapping
        local project_folder_name="Personal"  # default
        while IFS='|' read -r mapped_project_id mapped_folder_name; do
            if [[ "$mapped_project_id" == "$project_id" ]]; then
                project_folder_name="$mapped_folder_name"
                break
            fi
        done <<< "$project_mapping"
        
        # Build the target folder path: ProjectName/[FolderName]/workflow-id.json
        local folder_path="$target_dir/$project_folder_name"
        
        if [[ -n "$folder_name" && "$folder_name" != "" ]]; then
            # Sanitize folder name (remove invalid characters)
            local clean_folder_name=$(echo "$folder_name" | tr -d '[\/:*?"<>|]' | tr ' ' '_')
            folder_path="$folder_path/$clean_folder_name"
        fi
        
        # Create folder structure if it doesn't exist
        if [[ "$is_dry_run" == "true" ]]; then
            log DRYRUN "Would create folder: $folder_path"
        else
            if ! mkdir -p "$folder_path"; then
                log ERROR "Failed to create folder: $folder_path"
                rm -f "$temp_workflow"
                continue
            fi
        fi
        
        # Determine target filename
        local target_file="$folder_path/${workflow_id}.json"
        local is_new=true
        local commit_type="[New]"
        
        # Check if workflow already exists
        if [[ -f "$target_file" ]]; then
            is_new=false
            commit_type="[Updated]"
            # Compare files to see if there are actual changes
            if [[ "$is_dry_run" != "true" ]] && cmp -s "$temp_workflow" "$target_file" 2>/dev/null; then
                log DEBUG "Workflow $workflow_id unchanged: $workflow_name"
                rm -f "$temp_workflow"
                continue
            fi
        fi
        
        # Copy workflow to target location
        if [[ "$is_dry_run" == "true" ]]; then
            log DRYRUN "Would copy workflow $workflow_id to: $target_file ($commit_type $workflow_name)"
        else
            if cp "$temp_workflow" "$target_file"; then
                if $is_new; then
                    new_count=$((new_count + 1))
                    log SUCCESS "$commit_type Workflow $workflow_id: $workflow_name -> $target_file"
                else
                    updated_count=$((updated_count + 1))
                    log SUCCESS "$commit_type Workflow $workflow_id: $workflow_name -> $target_file"
                fi
            else
                log ERROR "Failed to copy workflow $workflow_id to: $target_file"
            fi
        fi
        
        rm -f "$temp_workflow"
        
    done <<< "$workflow_files"
    
    # Check for deleted workflows
    local deleted_count=0
    for existing_id in "${existing_workflows[@]}"; do
        local found=false
        for current_id in "${current_workflows[@]}"; do
            if [[ "$existing_id" == "$current_id" ]]; then
                found=true
                break
            fi
        done
        if ! $found; then
            # Find and remove deleted workflow files
            local deleted_files
            while IFS= read -r -d '' deleted_file; do
                if [[ "$is_dry_run" == "true" ]]; then
                    log DRYRUN "Would remove deleted workflow: $deleted_file"
                else
                    if rm "$deleted_file" 2>/dev/null; then
                        deleted_count=$((deleted_count + 1))
                        log SUCCESS "[Deleted] Removed workflow file: $deleted_file"
                    fi
                fi
            done < <(find "$target_dir" -name "${existing_id}.json" -type f -print0 2>/dev/null || true)
        fi
    done
    
    # Summary
    log INFO "Folder structure creation completed:"
    log INFO "  • New workflows: $new_count"
    log INFO "  • Updated workflows: $updated_count" 
    log INFO "  • Deleted workflows: $deleted_count"
    
    return 0
}

# Generate commit messages based on workflow changes
generate_workflow_commit_message() {
    local target_dir="$1"
    local is_dry_run="$2"
    
    # Count changes by examining Git status
    local new_files updated_files deleted_files
    
    if [[ "$is_dry_run" == "true" ]]; then
        echo "Backup workflow changes (dry run)"
        return 0
    fi
    
    # Use git status to detect changes
    pushd "$target_dir" > /dev/null || return 1
    
    # Get added files (new workflows)
    new_files=$(git status --porcelain 2>/dev/null | grep "^A " | wc -l)
    # Get modified files (updated workflows)  
    updated_files=$(git status --porcelain 2>/dev/null | grep "^M " | wc -l)
    # Get deleted files (removed workflows)
    deleted_files=$(git status --porcelain 2>/dev/null | grep "^D " | wc -l)
    
    popd > /dev/null || return 1
    
    # Generate appropriate commit message
    local commit_parts=()
    if [[ $new_files -gt 0 ]]; then
        commit_parts+=("$new_files new")
    fi
    if [[ $updated_files -gt 0 ]]; then
        commit_parts+=("$updated_files updated")
    fi
    if [[ $deleted_files -gt 0 ]]; then
        commit_parts+=("$deleted_files deleted")
    fi
    
    if [[ ${#commit_parts[@]} -eq 0 ]]; then
        echo "Workflow backup - no changes detected"
    elif [[ ${#commit_parts[@]} -eq 1 ]]; then
        echo "Workflow backup - ${commit_parts[0]} workflow(s)"
    else
        local message="Workflow backup - "
        for i in "${!commit_parts[@]}"; do
            if [[ $i -eq $((${#commit_parts[@]} - 1)) ]]; then
                message="${message} and ${commit_parts[$i]}"
            elif [[ $i -eq 0 ]]; then
                message="${message}${commit_parts[$i]}"
            else
                message="${message}, ${commit_parts[$i]}"
            fi
        done
        message="${message} workflow(s)"
        echo "$message"
    fi
}

rollback_restore() {
    local container_id="$1"
    local backup_dir="$2"
    local restore_type="$3"
    local is_dry_run=$4

    log WARN "Attempting to roll back to pre-restore state..."

    local backup_workflows="${backup_dir}/workflows.json"
    local backup_credentials="${backup_dir}/credentials.json"
    local container_workflows="/tmp/rollback_workflows.json"
    local container_credentials="/tmp/rollback_credentials.json"
    local rollback_success=true

    if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]] && [ ! -f "$backup_workflows" ]; then
        log ERROR "Pre-restore backup file workflows.json not found in $backup_dir. Cannot rollback workflows."
        rollback_success=false
    fi
    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]] && [ ! -f "$backup_credentials" ]; then
        log ERROR "Pre-restore backup file credentials.json not found in $backup_dir. Cannot rollback credentials."
        rollback_success=false
    fi
    if ! $rollback_success; then return 1; fi

    log INFO "Copying pre-restore backup files back to container..."
    local copy_failed=false
    if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
        if $is_dry_run; then
            log DRYRUN "Would copy $backup_workflows to ${container_id}:${container_workflows}"
        elif ! docker cp "$backup_workflows" "${container_id}:${container_workflows}"; then
            log ERROR "Rollback failed: Could not copy workflows back to container."
            copy_failed=true
        fi
    fi
    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
        if $is_dry_run; then
            log DRYRUN "Would copy $backup_credentials to ${container_id}:${container_credentials}"
        elif ! docker cp "$backup_credentials" "${container_id}:${container_credentials}"; then
            log ERROR "Rollback failed: Could not copy credentials back to container."
            copy_failed=true
        fi
    fi
    if $copy_failed; then 
        dockExec "$container_id" "rm -f $container_workflows $container_credentials" "$is_dry_run" || true
        return 1
    fi

    log INFO "Importing pre-restore backup data into n8n..."
    if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
        if ! dockExec "$container_id" "n8n import:workflow --separate --input=$container_workflows" "$is_dry_run"; then
            log ERROR "Rollback failed during workflow import."
            rollback_success=false
        fi
    fi
    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
        if ! dockExec "$container_id" "n8n import:credentials --separate --input=$container_credentials" "$is_dry_run"; then
            log ERROR "Rollback failed during credential import."
            rollback_success=false
        fi
    fi

    log INFO "Cleaning up rollback files in container..."
    dockExec "$container_id" "rm -f $container_workflows $container_credentials" "$is_dry_run" || log WARN "Could not clean up rollback files in container."

    if $rollback_success; then
        log SUCCESS "Rollback completed. n8n should be in the state before restore was attempted."
        return 0
    else
        log ERROR "Rollback failed. Manual intervention may be required."
        log WARN "Pre-restore backup files are kept at: $backup_dir"
        return 1
    fi
}

backup() {
    local container_id="$1"
    local github_token="$2"
    local github_repo="$3"
    local branch="$4"
    local use_dated_backup=$5
    local is_dry_run=$6
    local workflows_storage="${7:-local}"  # Where to store workflows (default: local)
    local credentials_storage="${8:-local}"  # Where to store credentials (default: local)
    local local_backup_path="${9:-$HOME/n8n-backup}"  # Local backup path (default: ~/n8n-backup)
    local local_rotation_limit="${10:-10}"  # Rotation limit (default: 10)

    log HEADER "Performing Backup - Workflows: $workflows_storage, Credentials: $credentials_storage"
    if $is_dry_run; then log WARN "DRY RUN MODE ENABLED - NO CHANGES WILL BE MADE"; fi
    
    # Show security warnings
    if [[ "$workflows_storage" == "remote" ]]; then
        log WARN "⚠️  Workflows will be stored in Git repository"
    fi
    if [[ "$credentials_storage" == "remote" ]]; then
        log WARN "⚠️  SECURITY WARNING: Credentials will be pushed to Git repository!"
    fi
    if [[ "$workflows_storage" == "local" && "$credentials_storage" == "local" ]]; then
        log INFO "🔒 Security: Both workflows and credentials stored locally only"
    fi
    if $is_dry_run; then log WARN "DRY RUN MODE ENABLED - NO CHANGES WILL BE MADE"; fi

    # Setup local backup storage directory with optional timestamping
    local base_backup_dir="$local_backup_path"
    local local_backup_dir="$base_backup_dir"
    
    # Apply timestamping to local storage if requested
    if [[ "$use_dated_backup" == "true" ]] && [[ "$workflows_storage" == "local" || "$credentials_storage" == "local" ]]; then
        local backup_timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
        local_backup_dir="$base_backup_dir/$backup_timestamp"
        log INFO "📅 Using timestamped local backup directory: $backup_timestamp"
    fi
    
    local local_workflows_file="$local_backup_dir/workflows.json"
    local local_credentials_file="$local_backup_dir/credentials.json"
    local local_env_file="$local_backup_dir/.env"
    
    if ! $is_dry_run; then
        if ! mkdir -p "$local_backup_dir"; then
            log ERROR "Failed to create local backup directory: $local_backup_dir"
            return 1
        fi
        chmod 700 "$local_backup_dir" || log WARN "Could not set permissions on local backup directory"
        
        # Also ensure base directory has proper permissions
        if [[ "$local_backup_dir" != "$base_backup_dir" ]]; then
            chmod 700 "$base_backup_dir" || log WARN "Could not set permissions on base backup directory"
        fi
        
        log SUCCESS "Local backup directory ready: $local_backup_dir"
    else
        log DRYRUN "Would create local backup directory: $local_backup_dir"
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d -t n8n-backup-XXXXXXXXXX)
    log DEBUG "Created temporary directory: $tmp_dir"

    local container_workflows="/tmp/workflows.json"
    local container_credentials="/tmp/credentials.json"
    local container_env="/tmp/.env"

    # --- Git Setup First --- 
    log INFO "Preparing Git repository for backup..."
    local git_repo_url="https://${github_token}@github.com/${github_repo}.git"

    log DEBUG "Initializing Git repository in $tmp_dir"
    if ! git -C "$tmp_dir" init -q; then log ERROR "Git init failed."; rm -rf "$tmp_dir"; return 1; fi
    log DEBUG "Adding remote 'origin' with URL $git_repo_url"
    if ! git -C "$tmp_dir" remote add origin "$git_repo_url" 2>/dev/null; then
        log WARN "Git remote 'origin' already exists. Setting URL..."
        if ! git -C "$tmp_dir" remote set-url origin "$git_repo_url"; then log ERROR "Git set-url failed."; rm -rf "$tmp_dir"; return 1; fi
    fi

    log INFO "Configuring Git user identity for commit..."
    if ! git -C "$tmp_dir" config user.email "n8n-backup-script@localhost"; then log ERROR "Failed to set Git user email."; rm -rf "$tmp_dir"; return 1; fi
    if ! git -C "$tmp_dir" config user.name "n8n Backup Script"; then log ERROR "Failed to set Git user name."; rm -rf "$tmp_dir"; return 1; fi

    log INFO "Fetching remote branch '$branch'..."
    local branch_exists=true
    if ! git -C "$tmp_dir" fetch --depth 1 origin "$branch" 2>/dev/null; then
        log WARN "Branch '$branch' not found on remote or repo is empty. Will create branch."
        branch_exists=false
        if ! $is_dry_run; then
             if ! git -C "$tmp_dir" checkout -b "$branch"; then log ERROR "Git checkout -b failed."; rm -rf "$tmp_dir"; return 1; fi
        else
             log DRYRUN "Would create and checkout new branch '$branch'"
        fi
    else
        if ! $is_dry_run; then
            if ! git -C "$tmp_dir" checkout "$branch"; then log ERROR "Git checkout failed."; rm -rf "$tmp_dir"; return 1; fi
        else
            log DRYRUN "Would checkout existing branch '$branch'"
        fi
    fi
    log SUCCESS "Git repository initialized and branch '$branch' checked out."

    # --- Export Data --- 
    log INFO "Exporting data from n8n container..."
    local export_failed=false
    local no_data_found=false

    # Export workflows using individual file method for Git restructuring
    local container_workflows_dir="/tmp/workflows"
    if [[ "$workflows_storage" == "remote" ]]; then
        log INFO "Exporting individual workflow files for Git folder structure..."
        if ! dockExec "$container_id" "mkdir -p $container_workflows_dir" false; then
            log ERROR "Failed to create workflows directory in container"
            export_failed=true
        elif ! dockExec "$container_id" "n8n export:workflow --backup --output=$container_workflows_dir/" false; then 
            # Check if the error is due to no workflows existing
            if docker exec "$container_id" n8n list workflows 2>&1 | grep -q "No workflows found"; then
                log INFO "No workflows found to backup - this is a clean installation"
                no_data_found=true
            else
                log ERROR "Failed to export individual workflow files"
                export_failed=true
            fi
        fi
    else
        log INFO "Exporting workflows as single file for local storage..."
        if ! dockExec "$container_id" "n8n export:workflow --all --output=$container_workflows" false; then 
            # Check if the error is due to no workflows existing
            if docker exec "$container_id" n8n list workflows 2>&1 | grep -q "No workflows found"; then
                log INFO "No workflows found to backup - this is a clean installation"
                no_data_found=true
            else
                log ERROR "Failed to export workflows"
                export_failed=true
            fi
        fi
    fi

    # Export credentials
    if [[ "$credentials_storage" == "local" || "$credentials_storage" == "remote" ]]; then
        log INFO "Exporting credentials for $credentials_storage storage..."
        if ! dockExec "$container_id" "n8n export:credentials --all --decrypted --output=$container_credentials" false; then 
            # Check if the error is due to no credentials existing
            if docker exec "$container_id" n8n list credentials 2>&1 | grep -q "No credentials found"; then
                log INFO "No credentials found to backup - this is a clean installation"
                no_data_found=true
            else
                log ERROR "Failed to export credentials"
                export_failed=true
            fi
        fi
    else
        log INFO "Credentials export skipped (not requested)"
    fi

    if $export_failed; then
        log ERROR "Failed to export data from n8n"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Handle environment variables (will be stored locally only - NOT pushed to Git)
    log INFO "Capturing environment variables for local storage only (NOT pushed to Git)..."
    if ! dockExec "$container_id" "printenv | grep ^N8N_ > $container_env" false; then
        log WARN "Could not capture N8N_ environment variables from container."
    fi

    # --- Process Local Storage ---
    log HEADER "Storing Data Locally"
    
    # Handle workflows locally if requested
    if [[ "$workflows_storage" == "local" ]] && docker exec "$container_id" test -f "$container_workflows"; then
        log INFO "Saving workflows to local storage..."
        if $is_dry_run; then
            log DRYRUN "Would copy workflows from container to local storage: $local_workflows_file"
            log DRYRUN "Would set permissions 600 on workflows file"
        else
            # Archive existing workflows only if NOT using timestamped directories
            # (timestamped directories naturally separate backups)
            if [[ "$use_dated_backup" != "true" ]] && [ -f "$local_workflows_file" ]; then
                log INFO "Archiving existing workflows before backup..."
                if ! archive_workflows "$local_workflows_file" "$base_backup_dir" "$is_dry_run" "$local_rotation_limit"; then
                    log WARN "Failed to archive existing workflows, but continuing..."
                fi
            fi

            # Copy new workflows from container to local storage
            if docker cp "${container_id}:${container_workflows}" "$local_workflows_file"; then
                chmod 600 "$local_workflows_file" || log WARN "Could not set permissions on workflows file"
                log SUCCESS "Workflows stored securely in local storage: $local_workflows_file"
            else
                log ERROR "Failed to copy workflows to local storage"
                rm -rf "$tmp_dir"
                return 1
            fi
        fi
    elif [[ "$workflows_storage" == "local" ]]; then
        log INFO "No workflows file found in container"
        if $no_data_found; then
            if ! $is_dry_run; then
                echo "[]" > "$local_workflows_file"
                chmod 600 "$local_workflows_file"
                log INFO "Created empty workflows file in local storage"
            else
                log DRYRUN "Would create empty workflows file in local storage"
            fi
        fi
    fi
    
    # Handle credentials locally  
    if [[ "$credentials_storage" == "local" ]] && docker exec "$container_id" test -f "$container_credentials"; then
        log INFO "Saving credentials to local secure storage..."
        if $is_dry_run; then
            log DRYRUN "Would copy credentials from container to local storage: $local_credentials_file"
            log DRYRUN "Would set permissions 600 on credentials file"
            log DRYRUN "Would archive previous credentials if they exist"
        else
            # Archive existing credentials only if NOT using timestamped directories
            # (timestamped directories naturally separate backups)
            if [[ "$use_dated_backup" != "true" ]] && [ -f "$local_credentials_file" ]; then
                log INFO "Archiving existing credentials before backup..."
                if ! archive_credentials "$local_credentials_file" "$base_backup_dir" "$is_dry_run" "$local_rotation_limit"; then
                    log WARN "Failed to archive existing credentials, but continuing..."
                fi
            fi

            # Copy new credentials from container to local storage
            if docker cp "${container_id}:${container_credentials}" "$local_credentials_file"; then
                chmod 600 "$local_credentials_file" || log WARN "Could not set permissions on credentials file"
                log SUCCESS "Credentials stored securely in local storage: $local_credentials_file"
            else
                log ERROR "Failed to copy credentials to local storage"
                rm -rf "$tmp_dir"
                return 1
            fi
        fi
    else
        log INFO "No credentials file found in container"
        if $no_data_found; then
            if ! $is_dry_run; then
                echo "[]" > "$local_credentials_file"
                chmod 600 "$local_credentials_file"
                log INFO "Created empty credentials file in local storage"
            else
                log DRYRUN "Would create empty credentials file in local storage"
            fi
        fi
    fi

    # Handle environment variables  
    if docker exec "$container_id" test -f "$container_env"; then
        log INFO "Saving environment variables to local secure storage..."
        if $is_dry_run; then
            log DRYRUN "Would copy environment variables from container to local storage: $local_env_file"
            log DRYRUN "Would set permissions 600 on environment file"
        else
            if docker cp "${container_id}:${container_env}" "$local_env_file"; then
                chmod 600 "$local_env_file" || log WARN "Could not set permissions on environment file"
                log SUCCESS "Environment variables stored securely in local storage: $local_env_file"
            else
                log WARN "Failed to copy environment variables to local storage"
            fi
        fi
    else
        log INFO "No environment variables file found in container"
    fi

    # If no data was found, create empty files to maintain backup structure (workflows only for Git)
    if $no_data_found; then
        log INFO "Creating empty workflow backup file for clean installation..."
        if ! docker exec "$container_id" test -f "$container_workflows"; then
            echo "[]" | docker exec -i "$container_id" sh -c "cat > $container_workflows"
        fi
    fi

    # --- Process Files for Git Repository (Conditional) ---
    local needs_git_repo=false
    if [[ "$workflows_storage" == "remote" || "$credentials_storage" == "remote" ]]; then
        needs_git_repo=true
        if [[ "$workflows_storage" == "remote" && "$credentials_storage" == "remote" ]]; then
            log HEADER "Preparing Files for Git Repository (Workflows + Credentials)"
        elif [[ "$workflows_storage" == "remote" ]]; then
            log HEADER "Preparing Workflows for Git Repository (Credentials Excluded)"
        else
            log HEADER "Preparing Credentials for Git Repository (Workflows Excluded)"
        fi
    else
        log INFO "Git repository not needed - all data stored locally"
        # Skip Git operations entirely
        needs_git_repo=false
    fi
    
    if ! $needs_git_repo; then
        log INFO "Cleaning up temporary files in container..."
        dockExec "$container_id" "rm -f $container_workflows $container_credentials $container_env" "$is_dry_run" || log WARN "Could not clean up temporary files in container."
        
        log SUCCESS "Backup completed - all data stored locally at: $local_backup_dir"
        return 0
    fi

    # Determine Target Directory and Copy Workflows Only
    local target_dir="$tmp_dir"
    local backup_timestamp=""
    if [ "$use_dated_backup" = "true" ]; then
        backup_timestamp="backup_$(timestamp)"
        target_dir="${tmp_dir}/${backup_timestamp}"
        log INFO "Using dated backup directory: $backup_timestamp"
        if [ "$is_dry_run" = "true" ]; then
            log DRYRUN "Would create directory: $target_dir"
        elif ! mkdir -p "$target_dir"; then
            log ERROR "Failed to create dated backup directory: $target_dir"
            rm -rf "$tmp_dir"
            return 1
        fi
    fi

    log INFO "Processing files for Git repository..."
    local copy_status="success" # Use string instead of boolean to avoid empty command errors
    
    # Process workflows for Git repository if requested
    if [[ "$workflows_storage" == "remote" ]]; then
        log INFO "Creating n8n folder structure for workflows..."
        
        # Create workflow folder structure mirroring n8n interface
        if ! create_n8n_folder_structure "$container_id" "$target_dir"; then
            log ERROR "Failed to create workflow folder structure"
            copy_status="failed"
        else
            log SUCCESS "Workflow folder structure created successfully in Git repository"
        fi
        
        # Clean up individual workflow files from container
        if [[ "$is_dry_run" != "true" ]]; then
            dockExec "$container_id" "rm -rf $container_workflows_dir" "$is_dry_run" || log WARN "Could not clean up workflows directory in container"
        fi
    else
        log INFO "Workflows will be stored locally only - not processing for Git"
    fi
    
    # Handle credentials file for Git repository if requested  
    if [[ "$credentials_storage" == "remote" ]]; then
        log INFO "Processing credentials for Git repository..."
        if docker exec "$container_id" test -f "$container_credentials"; then
            local creds_dest_file="${target_dir}/credentials.json"
            if [[ "$is_dry_run" == "true" ]]; then
                log DRYRUN "Would copy credentials to Git repository: $creds_dest_file"
            else
                local size
                size=$(docker exec "$container_id" du -h "$container_credentials" | awk '{print $1}' 2>/dev/null || echo "unknown")
                if docker cp "${container_id}:${container_credentials}" "$creds_dest_file"; then
                    log SUCCESS "Successfully copied credentials ($size) to Git directory: $creds_dest_file"
                else
                    log ERROR "Failed to copy credentials to Git directory"
                    copy_status="failed"
                fi
            fi
        else
            log INFO "No credentials file found in container - creating empty file"
            if [[ "$is_dry_run" != "true" ]]; then
                echo "[]" > "${target_dir}/credentials.json"
            fi
        fi
    else
        log INFO "Credentials will be stored locally only - not processing for Git"
    fi    # Create .gitignore based on credentials_storage setting
    local gitignore_file="${tmp_dir}/.gitignore"
    if $is_dry_run; then
        if [[ "$credentials_storage" == "remote" ]]; then
            log DRYRUN "Would create .gitignore with basic exclusions (credentials will be in Git)"
        else
            log DRYRUN "Would create .gitignore with credentials and environment exclusions"
        fi
    else
        if [[ "$credentials_storage" == "remote" ]]; then
            # When pushing credentials to Git, only exclude environment and temp files
            cat > "$gitignore_file" << 'EOF'
# n8n Security - Environment variables and temporary files only
.env
*.env
**/.env
**/*.env

# Archive directories
archive/

# OS and editor files
.DS_Store
Thumbs.db
*.swp
*.swo
*~

# Temporary files
*.tmp
*.temp
EOF
            log SUCCESS "Created .gitignore for credential-inclusive backup"
        else
            # Default secure mode: exclude all sensitive data
            cat > "$gitignore_file" << 'EOF'
# n8n Security - Never commit sensitive data
credentials.json
.env
*.env
**/credentials.json
**/.env
**/*.env

# Archive directories
archive/

# OS and editor files
.DS_Store
Thumbs.db
*.swp
*.swo
*~

# Temporary files
*.tmp
*.temp
EOF
            log SUCCESS "Created .gitignore to prevent sensitive data from being committed"
        fi
    fi
    
    # Check if workflow copy operations failed
    if [ "$copy_status" = "failed" ]; then 
        log ERROR "Workflow copy operations failed, aborting backup"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Force Git to see changes by updating a separate timestamp file instead of modifying the JSON files
    # This preserves the integrity of the n8n files for restore operations
    local ts_file="${tmp_dir}/backup_timestamp.txt"
    local backup_time=$(date +"%Y-%m-%d %H:%M:%S.%N")
    echo "Workflows backup generated at: $backup_time" > "$ts_file"
    if [[ "$credentials_storage" == "remote" ]]; then
        echo "Credentials included in Git repository" >> "$ts_file"
    else
        echo "Credentials stored locally at: $local_credentials_file" >> "$ts_file"
    fi
    echo "Environment stored locally at: $local_env_file" >> "$ts_file"
    log DEBUG "Created timestamp file $ts_file to track backup metadata"

    log INFO "Cleaning up temporary files in container..."
    dockExec "$container_id" "rm -f $container_workflows $container_credentials $container_env" "$is_dry_run" || log WARN "Could not clean up temporary files in container."

    # --- Git Commit and Push (Conditional Credentials) --- 
    if [[ "$credentials_storage" == "remote" ]]; then
        log HEADER "Committing Workflows and Credentials to Git"
    else
        log HEADER "Committing Workflows to Git (Credentials Excluded)"
    fi
    log INFO "Adding files to Git repository..."
    
    if $is_dry_run; then
        log DRYRUN "Would add workflow folder structure and files to Git index"
        if [[ "$credentials_storage" == "remote" ]]; then
            log DRYRUN "Would also add credentials file to Git index"
        fi
    else
        # Change to the git directory to avoid parsing issues
        cd "$tmp_dir" || { 
            log ERROR "Failed to change to git directory for add operation"; 
            rm -rf "$tmp_dir"; 
            return 1; 
        }
        
        # Create backup timestamp file
        date +"%Y-%m-%d %H:%M:%S" > backup_timestamp.txt
        
        # Always add the .gitignore and timestamp
        if ! git add .gitignore backup_timestamp.txt; then
            log ERROR "Git add failed for basic files"
            cd - > /dev/null || true
            rm -rf "$tmp_dir"
            return 1
        fi
        
        if [ "$use_dated_backup" = "true" ]; then
            # For dated backups, add the entire backup subdirectory with folder structure
            if [ -d "$backup_timestamp" ]; then
                log DEBUG "Adding dated backup directory with folder structure: $backup_timestamp"
                
                if ! git add "$backup_timestamp"; then
                    log ERROR "Git add failed for dated backup directory"
                    cd - > /dev/null || true
                    rm -rf "$tmp_dir"
                    return 1
                fi
            else
                log WARN "Backup directory not found: $backup_timestamp (may be empty)"
            fi
        else
            # Standard repo-root backup - add all workflow folders and files
            if [[ "$workflows_storage" == "remote" ]]; then
                log DEBUG "Adding workflow folder structure to repository root"
                
                # Add all workflow files and folders (but not hidden files except .gitignore)
                if ! git add --all .; then
                    log ERROR "Git add failed for workflow folder structure"
                    cd - > /dev/null || true
                    rm -rf "$tmp_dir"
                    return 1
                fi
                
                # Remove any accidentally added sensitive files if credentials not in remote
                if [[ "$credentials_storage" != "remote" ]]; then
                    git reset HEAD credentials.json 2>/dev/null || true
                    git reset HEAD .env 2>/dev/null || true
                fi
            fi
            
            # Handle credentials separately if needed
            if [[ "$credentials_storage" == "remote" ]] && [ -f "credentials.json" ]; then
                log DEBUG "Adding credentials file to Git"
                if ! git add credentials.json; then
                    log ERROR "Git add failed for credentials file"
                    cd - > /dev/null || true
                    rm -rf "$tmp_dir"
                    return 1
                fi
            fi
        fi
        
        # Success message
        if [[ "$workflows_storage" == "remote" && "$credentials_storage" == "remote" ]]; then
            log SUCCESS "Workflow folder structure and credentials added to Git successfully"
        elif [[ "$workflows_storage" == "remote" ]]; then
            log SUCCESS "Workflow folder structure added to Git successfully (credentials excluded)"
        else
            log SUCCESS "Files added to Git successfully"
        fi
        
        # Verify that files were staged correctly
        log DEBUG "Git staging status:"
        git status --short || true
    fi

    local n8n_ver
    n8n_ver=$(docker exec "$container_id" n8n --version 2>/dev/null || echo "unknown")
    log DEBUG "Detected n8n version: $n8n_ver"

    # --- Commit Logic ---
    if [[ "$credentials_storage" == "remote" ]]; then
        log INFO "Committing workflow and credential changes to Git..."
    else
        log INFO "Committing workflow changes to Git..."
    fi
    
    # Generate smart commit message based on actual changes
    local commit_msg
    if [[ "$workflows_storage" == "remote" ]]; then
        local workflow_changes
        workflow_changes=$(generate_workflow_commit_message "$target_dir" "$is_dry_run")
        if [[ "$credentials_storage" == "remote" ]]; then
            commit_msg="$workflow_changes + credentials"
        else
            commit_msg="$workflow_changes"
        fi
    else
        # Only credentials in Git (unlikely but possible)
        commit_msg="Credentials backup - $(date +"%Y-%m-%d_%H-%M-%S")"
    fi
    
    # Add n8n version and backup info
    local n8n_ver
    n8n_ver=$(docker exec "$container_id" n8n --version 2>/dev/null | grep -o 'n8n@[0-9.]*' | cut -d'@' -f2 || echo "unknown")
    commit_msg="$commit_msg (n8n v$n8n_ver)"
    
    if [ "$use_dated_backup" = "true" ]; then
        commit_msg="$commit_msg [$backup_timestamp]"
    fi
    
    # Ensure git identity is configured (important for non-interactive mode)
    # This is crucial according to developer notes about Git user identity
    if [[ -z "$(git config user.email 2>/dev/null)" ]]; then
        log WARN "No Git user.email configured, setting default"
        git config user.email "n8n-backup-script@localhost" || true
    fi
    if [[ -z "$(git config user.name 2>/dev/null)" ]]; then
        log WARN "No Git user.name configured, setting default"
        git config user.name "n8n Backup Script" || true
    fi
    
    # The timestamp file and .gitignore should already be created and added
    # No need to duplicate the git add operations here since they were done above
    
    # Skip Git's change detection and always commit
    log DEBUG "Committing workflow backup with message: $commit_msg"
    if [ "$is_dry_run" = "true" ]; then
        log DRYRUN "Would commit with message: $commit_msg"
        commit_status="success" # Assume commit would happen in dry run
    else
        # Force the commit with --allow-empty to ensure it happens
        if git commit --allow-empty -m "$commit_msg" 2>/dev/null; then
            commit_status="success" # Set flag to indicate commit success
            log SUCCESS "Changes committed successfully"
        else
            log ERROR "Git commit failed"
            # Show detailed output in case of failure
            git status || true
            cd - > /dev/null || true
            rm -rf "$tmp_dir"
            return 1
        fi
    fi
    
    # We'll maintain the directory change until after push completes in the next section

    # --- Push Logic --- 
    log INFO "Pushing backup to GitHub repository '$github_repo' branch '$branch'..."
    
    if [ "$is_dry_run" = "true" ]; then
        log DRYRUN "Would push branch '$branch' to origin"
        return 0
    fi
    
    # Simple approach - we just committed changes successfully
    # So we'll push those changes now
    cd "$tmp_dir" || { log ERROR "Failed to change to $tmp_dir"; rm -rf "$tmp_dir"; return 1; }
    
    # Check if git log shows recent commits
    last_commit=$(git log -1 --pretty=format:"%H" 2>/dev/null)
    if [ -z "$last_commit" ]; then
        log ERROR "No commits found to push"
        cd - > /dev/null || true
        rm -rf "$tmp_dir"
        return 1
    fi
    
    # Found a commit, so push it
    log DEBUG "Pushing commit $last_commit to origin/$branch"
    
    # Use a direct git command with full output
    if ! git push -u origin "$branch" --verbose; then
        log ERROR "Failed to push to GitHub - connectivity issue or permissions problem"
        
        # Test GitHub connectivity
        if ! curl -s -I "https://github.com" > /dev/null; then
            log ERROR "Cannot reach GitHub - network connectivity issue"
        elif ! curl -s -H "Authorization: token $github_token" "https://api.github.com/user" | grep -q login; then
            log ERROR "GitHub API authentication failed - check token permissions"
        else
            log ERROR "Unknown error pushing to GitHub"
        fi
        
        cd - > /dev/null || true
        rm -rf "$tmp_dir"
        return 1
    fi
    
    log SUCCESS "Workflow backup successfully pushed to GitHub repository"
    cd - > /dev/null || true

    # Clean up temporary files in container
    log INFO "Cleaning up temporary files in container..."
    if [[ "$is_dry_run" == "true" ]]; then
        log DRYRUN "Would clean up temporary files in container"
    else
        # Clean up both old single-file format and new directory format
        dockExec "$container_id" "rm -f $container_workflows $container_credentials $container_env" "$is_dry_run" || log WARN "Could not clean up single files in container"
        dockExec "$container_id" "rm -rf $container_workflows_dir" "$is_dry_run" || log WARN "Could not clean up workflows directory in container"
    fi

    log INFO "Cleaning up host temporary directory..."
    if $is_dry_run; then
        log DRYRUN "Would remove temporary directory: $tmp_dir"
    else
        rm -rf "$tmp_dir"
    fi

    log HEADER "Backup Summary"
    
    # Show what was actually backed up and where
    if [[ "$workflows_storage" == "remote" ]]; then
        log SUCCESS "✅ Workflows: Successfully backed up to GitHub repository"
    elif [[ "$workflows_storage" == "local" ]]; then
        log SUCCESS "✅ Workflows: Securely stored locally at $local_workflows_file"
    fi
    
    if [[ "$credentials_storage" == "remote" ]]; then
        log SUCCESS "🔒 Credentials: Stored in GitHub repository"
        log WARN "⚠️  Security: Credentials are stored in Git repository (less secure)"
    elif [[ "$credentials_storage" == "local" ]]; then
        log SUCCESS "🔒 Credentials: Securely stored locally at $local_credentials_file"
    fi
    
    log SUCCESS "🌍 Environment: Securely stored locally at $local_env_file"
    log INFO "📁 Local backup directory: $local_backup_dir"
    
    # Rotate old timestamped local backups if using timestamped directories
    if [[ "$use_dated_backup" == "true" ]] && [[ "$workflows_storage" == "local" || "$credentials_storage" == "local" ]]; then
        log INFO "Rotating old timestamped local backups..."
        rotate_local_timestamped_backups "$base_backup_dir" "$local_rotation_limit" "$is_dry_run"
    fi
    
    if $is_dry_run; then log WARN "(Dry run mode was active - no changes made)"; fi
    return 0
}

restore() {
    local container_id="$1"
    local github_token="$2"
    local github_repo="$3"
    local branch="$4"
    local restore_type="$5"
    local is_dry_run=$6

    log HEADER "Performing Restore from GitHub (Type: $restore_type)"
    if $is_dry_run; then log WARN "DRY RUN MODE ENABLED - NO CHANGES WILL BE MADE"; fi
    
    # Show restore plan for clarity
    if [ -t 0 ] && ! $is_dry_run; then
        show_restore_plan "$restore_type" "$github_repo" "$branch"
    fi

    if [ -t 0 ] && ! $is_dry_run; then
        printf "Are you sure you want to proceed? (yes/no): "
        local confirm
        read -r confirm
        if [[ "$confirm" != "yes" && "$confirm" != "y" ]]; then
            log INFO "Restore cancelled by user."
            return 0
        fi
    elif ! $is_dry_run; then
        log WARN "Running restore non-interactively (type: $restore_type). Proceeding without confirmation."
    fi

    # --- 1. Pre-restore Backup --- 
    log HEADER "Step 1: Creating Pre-restore Backup"
    local pre_restore_dir=""
    pre_restore_dir=$(mktemp -d -t n8n-prerestore-XXXXXXXXXX)
    log DEBUG "Created pre-restore backup directory: $pre_restore_dir"

    local pre_workflows="${pre_restore_dir}/workflows.json"
    local pre_credentials="${pre_restore_dir}/credentials.json"
    local container_pre_workflows="/tmp/pre_workflows.json"
    local container_pre_credentials="/tmp/pre_credentials.json"

    local backup_failed=false
    local no_existing_data=false
    log INFO "Exporting current n8n data for backup..."
    
    # Function to check if output indicates no data
    check_no_data() {
        local output="$1"
        if echo "$output" | grep -q "No workflows found" || echo "$output" | grep -q "No credentials found"; then
            return 0
        fi
        return 1
    }

    if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
        local workflow_output
        workflow_output=$(docker exec "$container_id" n8n export:workflow --all --output=$container_pre_workflows 2>&1) || {
            if check_no_data "$workflow_output"; then
                log INFO "No existing workflows found - this is a clean installation"
                no_existing_data=true
                # Create empty workflows file
                echo "[]" | docker exec -i "$container_id" sh -c "cat > $container_pre_workflows"
            else
                log ERROR "Failed to export workflows: $workflow_output"
                backup_failed=true
            fi
        }
    fi

    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
        if ! $backup_failed; then
            local cred_output
            cred_output=$(docker exec "$container_id" n8n export:credentials --all --decrypted --output=$container_pre_credentials 2>&1) || {
                if check_no_data "$cred_output"; then
                    log INFO "No existing credentials found - this is a clean installation"
                    no_existing_data=true
                    # Create empty credentials file
                    echo "[]" | docker exec -i "$container_id" sh -c "cat > $container_pre_credentials"
                else
                    log ERROR "Failed to export credentials: $cred_output"
                    backup_failed=true
                fi
            }
        fi
    fi

    if $backup_failed; then
        log WARN "Could not export current data completely. Cannot create pre-restore backup."
        dockExec "$container_id" "rm -f $container_pre_workflows $container_pre_credentials" false || true
        rm -rf "$pre_restore_dir"
        pre_restore_dir=""
        if ! $is_dry_run; then
            log ERROR "Cannot proceed with restore safely without pre-restore backup."
            return 1
        fi
    elif $no_existing_data; then
        log INFO "No existing data found - proceeding with restore without pre-restore backup"
        # Copy the empty files we created to the backup directory
        if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
            docker cp "${container_id}:${container_pre_workflows}" "$pre_workflows" || true
        fi
        if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
            docker cp "${container_id}:${container_pre_credentials}" "$pre_credentials" || true
        fi
        dockExec "$container_id" "rm -f $container_pre_workflows $container_pre_credentials" false || true
    else
        log INFO "Copying current data to host backup directory..."
        local copy_failed=false
        if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
            if $is_dry_run; then
                log DRYRUN "Would copy ${container_id}:${container_pre_workflows} to $pre_workflows"
            elif ! docker cp "${container_id}:${container_pre_workflows}" "$pre_workflows"; then copy_failed=true; fi
        fi
        if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
             if $is_dry_run; then
                 log DRYRUN "Would copy ${container_id}:${container_pre_credentials} to $pre_credentials"
             elif ! docker cp "${container_id}:${container_pre_credentials}" "$pre_credentials"; then copy_failed=true; fi
        fi
        
        dockExec "$container_id" "rm -f $container_pre_workflows $container_pre_credentials" "$is_dry_run" || true

        if $copy_failed; then
            log ERROR "Failed to copy backup files from container. Cannot proceed with restore safely."
            rm -rf "$pre_restore_dir"
            return 1
        else
            log SUCCESS "Pre-restore backup created successfully."
        fi
    fi

    # --- 2. Fetch from GitHub --- 
    log HEADER "Step 2: Fetching Backup from GitHub"
    local download_dir
    download_dir=$(mktemp -d -t n8n-download-XXXXXXXXXX)
    log DEBUG "Created download directory: $download_dir"

    local git_repo_url="https://${github_token}@github.com/${github_repo}.git"
    log INFO "Cloning repository $github_repo branch $branch..."
    
    log DEBUG "Running: git clone --depth 1 --branch $branch $git_repo_url $download_dir"
    if ! git clone --depth 1 --branch "$branch" "$git_repo_url" "$download_dir"; then
        log ERROR "Failed to clone repository. Check URL, token, branch, and permissions."
        rm -rf "$download_dir"
        if [ -n "$pre_restore_dir" ]; then log WARN "Pre-restore backup kept at: $pre_restore_dir"; fi
        return 1
    fi

    # Check if the restore should come from a dated backup directory
    local dated_backup_found=false
    local selected_backup=""
    local backup_dirs=()
    
    # Look for dated backup directories
    cd "$download_dir" || { 
        log ERROR "Failed to change to download directory";
        rm -rf "$download_dir";
        if [ -n "$pre_restore_dir" ]; then log WARN "Pre-restore backup kept at: $pre_restore_dir"; fi;
        return 1;
    }
    
    # Debug - show what files exist in the repository
    log DEBUG "Repository root contents:"
    ls -la "$download_dir" || true
    find "$download_dir" -type f -name "*.json" | sort || true
    
    # Find all backup_* directories and sort them by date (newest first)
    readarray -t backup_dirs < <(find . -type d -name "backup_*" | sort -r)
    
    if [ ${#backup_dirs[@]} -gt 0 ]; then
        log INFO "Found ${#backup_dirs[@]} dated backup(s):"
        
        # If non-interactive mode, automatically select the most recent backup
        if ! [ -t 0 ]; then
            selected_backup="${backup_dirs[0]}"
            dated_backup_found=true
            log INFO "Auto-selecting most recent backup in non-interactive mode: $selected_backup"
        else
            # Interactive mode - show menu with newest backups first
            echo ""
            echo "Select a backup to restore:"
            echo "------------------------------------------------"
            echo "0) Use files from repository root (not a dated backup)"
            
            for i in "${!backup_dirs[@]}"; do
                # Extract the date part from backup_YYYY-MM-DD_HH-MM-SS format
                local backup_date="${backup_dirs[$i]#./backup_}"
                echo "$((i+1))) ${backup_date} (${backup_dirs[$i]})"
            done
            echo "------------------------------------------------"
            
            local valid_selection=false
            while ! $valid_selection; do
                echo -n "Select a backup number (0-${#backup_dirs[@]}): "
                local selection
                read -r selection
                
                if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -le "${#backup_dirs[@]}" ]; then
                    valid_selection=true
                    
                    if [ "$selection" -eq 0 ]; then
                        log INFO "Using repository root files (not a dated backup)"
                    else
                        selected_backup="${backup_dirs[$((selection-1))]}"
                        dated_backup_found=true
                        log INFO "Selected backup: $selected_backup"
                    fi
                else
                    echo "Invalid selection. Please enter a number between 0 and ${#backup_dirs[@]}."
                fi
            done
        fi
    fi
    
    # EMERGENCY DIRECT APPROACH: Use the files from repository without complex validation
    log INFO "Direct approach: Using files straight from repository..."
    
    # Set up container import paths
    local container_import_workflows="/tmp/import_workflows.json"
    local container_import_credentials="/tmp/import_credentials.json"
    
    # Find the workflow and credentials files directly
    local repo_workflows=""
    local repo_credentials=""
    
    # First try dated backup if specified
    if $dated_backup_found; then
        local dated_path="${selected_backup#./}"
        log INFO "Looking for files in dated backup: $dated_path"
        
        if [ -f "${download_dir}/${dated_path}/workflows.json" ]; then
            repo_workflows="${download_dir}/${dated_path}/workflows.json"
            log SUCCESS "Found workflows.json in dated backup directory"
        fi
        
        if [ -f "${download_dir}/${dated_path}/credentials.json" ]; then
            repo_credentials="${download_dir}/${dated_path}/credentials.json"
            log SUCCESS "Found credentials.json in dated backup directory"
        fi
    fi
    
    # Fall back to repository root if files weren't found in dated backup
    if [ -z "$repo_workflows" ] && [ -f "${download_dir}/workflows.json" ]; then
        repo_workflows="${download_dir}/workflows.json"
        log SUCCESS "Found workflows.json in repository root"
    fi
    
    # Handle credentials differently - check local storage first, then Git repo for backwards compatibility
    local local_backup_dir="$HOME/n8n-backup"
    local local_credentials_file="$local_backup_dir/credentials.json"
    
    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
        log INFO "Checking for credentials in local secure storage..."
        
        # Check local storage first (preferred method)
        if [ -f "$local_credentials_file" ] && [ -s "$local_credentials_file" ]; then
            repo_credentials="$local_credentials_file"
            log SUCCESS "Found credentials in local secure storage: $local_credentials_file"
        # Check for dated backup credentials in Git
        elif [ -n "$selected_backup" ] && [ -f "${download_dir}${selected_backup}/credentials.json" ] && [ -s "${download_dir}${selected_backup}/credentials.json" ]; then
            repo_credentials="${download_dir}${selected_backup}/credentials.json"
            log WARN "Found credentials in Git repository dated backup (legacy method)"
            log WARN "⚠️  Security recommendation: Use newer backup method that stores credentials locally"
        # Check repository root for credentials
        elif [ -f "${download_dir}/credentials.json" ] && [ -s "${download_dir}/credentials.json" ]; then
            repo_credentials="${download_dir}/credentials.json"
            log WARN "Found credentials in Git repository root (legacy method)"
            log WARN "⚠️  Security recommendation: Use newer backup method that stores credentials locally"
        else
            log ERROR "No credentials found for $restore_type restore"
            log ERROR "Searched locations:"
            log ERROR "  • Local secure storage: $local_credentials_file (preferred)"
            if [ -n "$selected_backup" ]; then
                log ERROR "  • Git dated backup: ${download_dir}${selected_backup}/credentials.json"
            fi
            log ERROR "  • Git repository root: ${download_dir}/credentials.json"
            log ERROR "📝 To fix: Either use a backup that includes credentials, or restore workflows-only"
            file_validation_passed=false
        fi
    fi
    
    # Check for workflows in Git repository  
    if [ -z "$repo_workflows" ] && [ -f "${download_dir}/workflows.json" ]; then
        repo_workflows="${download_dir}/workflows.json"
        log SUCCESS "Found workflows.json in repository root"
    fi
    
    # Display file sizes for debug purposes
    if [ -n "$repo_workflows" ]; then
        log DEBUG "Workflow file size: $(du -h "$repo_workflows" | cut -f1)"
    fi
    
    if [ -n "$repo_credentials" ]; then
        local cred_location="local storage"
        if [[ "$repo_credentials" == *"/credentials.json" ]] && [[ "$repo_credentials" != "$local_credentials_file" ]]; then
            cred_location="Git repository (legacy)"
        fi
        log DEBUG "Credentials file size: $(du -h "$repo_credentials" | cut -f1) [from $cred_location]"
    fi
    
    # Proceed directly to import phase
    log INFO "Validating files for import..."
    local file_validation_passed=true
    
    # More robust file checking logic
    if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
        if [ ! -f "$repo_workflows" ] || [ ! -s "$repo_workflows" ]; then
            log ERROR "Valid workflows.json not found for $restore_type restore"
            file_validation_passed=false
        else
            log SUCCESS "Workflows file validated for import"
        fi
    fi
    
    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
        if [ ! -f "$repo_credentials" ] || [ ! -s "$repo_credentials" ]; then
            log ERROR "Valid credentials.json not found for $restore_type restore"
            log ERROR "💡 Suggestion: Try --restore-type workflows to restore workflows only"
            log ERROR "💡 Alternative: Create new credentials in n8n after workflow restore"
            file_validation_passed=false
        else
            local cred_source_desc="local secure storage"
            if [[ "$repo_credentials" != "$local_credentials_file" ]]; then
                cred_source_desc="Git repository (legacy backup)"
            fi
            log SUCCESS "Credentials file validated for import from $cred_source_desc"
        fi
    fi
    
    # Always use explicit comparison for clarity and to avoid empty commands
    if [ "$file_validation_passed" != "true" ]; then
        log ERROR "File validation failed. Cannot proceed with restore."
        log DEBUG "Repository contents (excluding .git):"
        find "$download_dir" -type f -not -path "*/\.git/*" | sort || true
        rm -rf "$download_dir"
        if [ -n "$pre_restore_dir" ]; then log WARN "Pre-restore backup kept at: $pre_restore_dir"; fi
        return 1
    fi
    
    log SUCCESS "All required files validated successfully."
    
    # Skip temp directory completely and copy directly to container
    log INFO "Copying downloaded files directly to container..."
    
    local copy_status="success" # Use string instead of boolean to avoid empty command errors
    
    # Copy workflow file if needed
    if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
        if [ "$is_dry_run" = "true" ]; then
            log DRYRUN "Would copy $repo_workflows to ${container_id}:${container_import_workflows}"
        else
            log INFO "Copying workflows file to container..."
            if docker cp "$repo_workflows" "${container_id}:${container_import_workflows}"; then
                log SUCCESS "Successfully copied workflows.json to container"
            else
                log ERROR "Failed to copy workflows.json to container."
                copy_status="failed"
            fi
        fi
    fi
    
    # Copy credentials file if needed
    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
        if [ "$is_dry_run" = "true" ]; then
            log DRYRUN "Would copy $repo_credentials to ${container_id}:${container_import_credentials}"
        else
            log INFO "Copying credentials file to container..."
            if docker cp "$repo_credentials" "${container_id}:${container_import_credentials}"; then
                log SUCCESS "Successfully copied credentials.json to container"
            else
                log ERROR "Failed to copy credentials.json to container."
                copy_status="failed"
            fi
        fi
    fi
    
    # Check copy status with explicit string comparison
    if [ "$copy_status" = "failed" ]; then
        log ERROR "Failed to copy files to container - cannot proceed with restore"
        rm -rf "$download_dir"
        if [ -n "$pre_restore_dir" ]; then log WARN "Pre-restore backup kept at: $pre_restore_dir"; fi
        return 1
    fi
    
    log SUCCESS "All files copied to container successfully."
    
    # Handle import directly here to avoid another set of checks
    log INFO "Importing data into n8n..."
    local import_status="success"
    
    # Import workflows if needed
    if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
        if [ "$is_dry_run" = "true" ]; then
            log DRYRUN "Would run: n8n import:workflow --input=$container_import_workflows"
        else
            log INFO "Importing workflows..."
            local import_output
            import_output=$(docker exec "$container_id" n8n import:workflow --input=$container_import_workflows 2>&1) || {
                # Check for specific error conditions
                if echo "$import_output" | grep -q "already exists"; then
                    log WARN "Some workflows already exist - attempting to update them..."
                    if ! dockExec "$container_id" "n8n import:workflow --input=$container_import_workflows --force" "$is_dry_run"; then
                        log ERROR "Failed to import/update workflows"
                        import_status="failed"
                    else
                        log SUCCESS "Workflows imported/updated successfully"
                    fi
                else
                    log ERROR "Failed to import workflows: $import_output"
                    import_status="failed"
                fi
            }
        fi
    fi
    
    # Import credentials if needed
    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
        if [ "$is_dry_run" = "true" ]; then
            log DRYRUN "Would run: n8n import:credentials --input=$container_import_credentials"
        else
            log INFO "Importing credentials..."
            local import_output
            import_output=$(docker exec "$container_id" n8n import:credentials --input=$container_import_credentials 2>&1) || {
                # Check for specific error conditions
                if echo "$import_output" | grep -q "already exists"; then
                    log WARN "Some credentials already exist - attempting to update them..."
                    if ! dockExec "$container_id" "n8n import:credentials --input=$container_import_credentials --force" "$is_dry_run"; then
                        log ERROR "Failed to import/update credentials"
                        import_status="failed"
                    else
                        log SUCCESS "Credentials imported/updated successfully"
                    fi
                else
                    log ERROR "Failed to import credentials: $import_output"
                    import_status="failed"
                fi
            }
        fi
    fi
    
    # Clean up temporary files in container
    if [ "$is_dry_run" != "true" ]; then
        log INFO "Cleaning up temporary files in container..."
        # Try a more Alpine-friendly approach - first check if files exist
        if dockExec "$container_id" "[ -f $container_import_workflows ] && echo 'Workflow file exists'" "$is_dry_run"; then
            # Try with ash shell explicitly (common in Alpine)
            dockExec "$container_id" "ash -c 'rm -f $container_import_workflows 2>/dev/null || true'" "$is_dry_run" || true
            log DEBUG "Attempted cleanup of workflow import file"
        fi
        
        if dockExec "$container_id" "[ -f $container_import_credentials ] && echo 'Credentials file exists'" "$is_dry_run"; then
            # Try with ash shell explicitly (common in Alpine)
            dockExec "$container_id" "ash -c 'rm -f $container_import_credentials 2>/dev/null || true'" "$is_dry_run" || true
            log DEBUG "Attempted cleanup of credentials import file"
        fi
        
        log INFO "Temporary files in container will be automatically removed when container restarts"
    fi
    
    # Cleanup downloaded repository
    rm -rf "$download_dir"
    
    # Handle restore result based on import status
    if [ "$import_status" = "failed" ]; then
        log WARN "Restore partially completed with some errors. Check logs for details."
        if [ -n "$pre_restore_dir" ]; then 
            log WARN "Pre-restore backup kept at: $pre_restore_dir" 
        fi
        return 1
    fi
    
    # Success - restore completed successfully
    log HEADER "Restore Summary"
    
    # Determine credential source for accurate reporting
    local cred_source="unknown"
    if [ -n "$repo_credentials" ]; then
        if [[ "$repo_credentials" == "$local_credentials_file" ]]; then
            cred_source="local secure storage"
        else
            cred_source="Git repository (legacy)"
        fi
    fi
    
    if [[ "$restore_type" == "all" ]]; then
        log SUCCESS "✅ Complete restore completed successfully!"
        log SUCCESS "📄 Workflows: Restored from Git repository"
        log SUCCESS "🔒 Credentials: Restored from $cred_source"
    elif [[ "$restore_type" == "workflows" ]]; then
        log SUCCESS "✅ Workflows restore completed successfully!"
        log SUCCESS "📄 Workflows: Restored from Git repository"
        log INFO "🔒 Credentials: Unchanged (not restored)"
    elif [[ "$restore_type" == "credentials" ]]; then
        log SUCCESS "✅ Credentials restore completed successfully!"
        log SUCCESS "🔒 Credentials: Restored from $cred_source"
        log INFO "📄 Workflows: Unchanged (not restored)"
    fi
    
    if [ -n "$repo_credentials" ] && [[ "$repo_credentials" != "$local_credentials_file" ]]; then
        log WARN "⚠️  Note: Credentials were restored from Git repository (legacy backup)"
        log WARN "⚠️  Consider using newer backup method that stores credentials locally"
    fi
    
    # Clean up pre-restore backup if successful
    if [ -n "$pre_restore_dir" ] && [ "$is_dry_run" != "true" ]; then
        rm -rf "$pre_restore_dir"
        log INFO "Pre-restore backup cleaned up."
    fi
    
    return 0 # Explicitly return success
}

# --- Main Function --- 
main() {
    # Parse command-line arguments first
    while [ $# -gt 0 ]; do
        case "$1" in
            --action) ARG_ACTION="$2"; shift 2 ;; 
            --container) ARG_CONTAINER="$2"; shift 2 ;; 
            --token) ARG_TOKEN="$2"; shift 2 ;; 
            --repo) ARG_REPO="$2"; shift 2 ;; 
            --branch) ARG_BRANCH="$2"; shift 2 ;; 
            --config) ARG_CONFIG_FILE="$2"; shift 2 ;; 
            --dated) ARG_DATED_BACKUPS=true; shift 1 ;;
            --workflows)
                if [ $# -gt 1 ] && [[ "$2" == "local" || "$2" == "remote" ]]; then
                    ARG_WORKFLOWS_STORAGE="$2"; shift 2
                else
                    ARG_WORKFLOWS_STORAGE="local"; shift 1  # Default to local if no argument
                fi ;;
            --credentials)
                if [ $# -gt 1 ] && [[ "$2" == "local" || "$2" == "remote" ]]; then
                    ARG_CREDENTIALS_STORAGE="$2"; shift 2
                else
                    ARG_CREDENTIALS_STORAGE="local"; shift 1  # Default to local if no argument
                fi ;;
            --path) ARG_LOCAL_BACKUP_PATH="$2"; shift 2 ;;
            --rotation) 
                if [[ "$2" =~ ^[0-9]+$ ]] || [[ "$2" == "unlimited" ]]; then
                    ARG_LOCAL_ROTATION_LIMIT="$2"; shift 2
                else
                    echo -e "${RED}[ERROR]${NC} Invalid --rotation value: '$2'." >&2
                    echo -e "${YELLOW}[INFO]${NC} Valid options:" >&2
                    echo -e "${YELLOW}[INFO]${NC}   • 0          - No rotation (overwrite current backup)" >&2
                    echo -e "${YELLOW}[INFO]${NC}   • <number>   - Keep N most recent backups (creates archive/timestamp dirs)" >&2
                    echo -e "${YELLOW}[INFO]${NC}   • unlimited  - Keep all backups (no deletion)" >&2
                    exit 1
                fi ;;
            --restore-type) 
                if [[ "$2" == "all" || "$2" == "workflows" || "$2" == "credentials" ]]; then
                    ARG_RESTORE_TYPE="$2"
                else
                    echo -e "${RED}[ERROR]${NC} Invalid --restore-type: '$2'." >&2
                    echo -e "${YELLOW}[INFO]${NC} Valid options:" >&2
                    echo -e "${YELLOW}[INFO]${NC}   • all        - Restore workflows and credentials" >&2
                    echo -e "${YELLOW}[INFO]${NC}   • workflows  - Restore workflows only (credentials unchanged)" >&2
                    echo -e "${YELLOW}[INFO]${NC}   • credentials - Restore credentials only (workflows unchanged)" >&2
                    exit 1
                fi
                shift 2 ;;
            --dry-run) ARG_DRY_RUN=true; shift 1 ;; 
            --verbose) ARG_VERBOSE=true; shift 1 ;; 
            --log-file) ARG_LOG_FILE="$2"; shift 2 ;; 
            --folder-structure) ARG_FOLDER_STRUCTURE=true; shift 1 ;;
            --n8n-url) ARG_N8N_BASE_URL="$2"; shift 2 ;;
            --n8n-api-key) ARG_N8N_API_KEY="$2"; shift 2 ;;
            --trace) DEBUG_TRACE=true; shift 1;; 
            -h|--help) show_help; exit 0 ;; 
            *) echo -e "${RED}[ERROR]${NC} Invalid option: $1" >&2; show_help; exit 1 ;; 
        esac
    done

    # Load config file (must happen after parsing args)
    load_config

    log HEADER "n8n Backup/Restore Manager v$VERSION"
    log INFO "� Flexible backup storage: local files or Git repository (user configurable)"
    if [ "$ARG_DRY_RUN" = "true" ]; then log WARN "DRY RUN MODE ENABLED"; fi
    if [ "$ARG_VERBOSE" = "true" ]; then log DEBUG "Verbose mode enabled."; fi
    
    check_host_dependencies

    # Use local variables within main
    local action="$ARG_ACTION"
    local container_id="$ARG_CONTAINER"
    local github_token="$ARG_TOKEN"
    local github_repo="$ARG_REPO"
    local branch="${ARG_BRANCH:-main}"
    local use_dated_backup=$ARG_DATED_BACKUPS
    local workflows_storage="$ARG_WORKFLOWS_STORAGE"
    local credentials_storage="$ARG_CREDENTIALS_STORAGE"
    local local_backup_path="${ARG_LOCAL_BACKUP_PATH:-$HOME/n8n-backup}"
    local local_rotation_limit="${ARG_LOCAL_ROTATION_LIMIT:-10}"  # Default to 10 if not specified
    local restore_type="${ARG_RESTORE_TYPE:-all}"  # Keep for backwards compatibility
    local is_dry_run=$ARG_DRY_RUN
    
    # Set intelligent defaults for backup - require explicit storage specification
    if [[ "$action" == "backup" ]]; then
        if [[ -z "$workflows_storage" && -z "$credentials_storage" ]]; then
            # Neither specified - no backup operation (user must be explicit)
            log ERROR "No storage options specified. Please specify --workflows and/or --credentials with 'local' or 'remote'"
            log INFO "Examples:"
            log INFO "  --workflows remote --credentials local    (workflows to Git, credentials local)"
            log INFO "  --workflows local --credentials local     (both local only)"
            log INFO "  --workflows remote                        (workflows to Git only)"
            log INFO "  --credentials local                       (credentials local only)"
            exit 1
        elif [[ -z "$workflows_storage" ]]; then
            # Only credentials specified - default workflows to remote (Git) for typical use case
            workflows_storage="remote"
            log INFO "Workflows storage not specified - defaulting to remote (Git repository)"
        elif [[ -z "$credentials_storage" ]]; then
            # Only workflows specified - default credentials to local (secure)
            credentials_storage="local"
            log INFO "Credentials storage not specified - defaulting to local (secure)"
        fi
    fi

    log DEBUG "Initial Action: $action"
    log DEBUG "Initial Container: $container_id"
    log DEBUG "Initial Repo: $github_repo"
    log DEBUG "Initial Branch: $branch"
    log DEBUG "Initial Dated Backup: $use_dated_backup"
    log DEBUG "Initial Workflows Storage: $workflows_storage"
    log DEBUG "Initial Credentials Storage: $credentials_storage"
    log DEBUG "Initial Local Backup Path: $local_backup_path"
    log DEBUG "Initial Restore Type: $restore_type"
    log DEBUG "Initial Dry Run: $is_dry_run"
    log DEBUG "Initial Verbose: $ARG_VERBOSE"
    log DEBUG "Initial Log File: $ARG_LOG_FILE"

    # Check if running non-interactively
    if ! [ -t 0 ]; then
        log DEBUG "Running in non-interactive mode."
        
        # Basic parameters are always required
        if [ -z "$action" ] || [ -z "$container_id" ]; then
            log ERROR "Running in non-interactive mode but required parameters are missing."
            log INFO "Please provide --action and --container via arguments or config file."
            show_help
            exit 1
        fi
        
        # GitHub parameters only required for remote operations or restore
        if [[ "$action" == "restore" ]] || [[ "$workflows_storage" == "remote" ]] || [[ "$credentials_storage" == "remote" ]]; then
            if [ -z "$github_token" ] || [ -z "$github_repo" ]; then
                log ERROR "GitHub token and repository are required for remote operations or restore."
                log INFO "Please provide --token and --repo via arguments or config file."
                show_help
                exit 1
            fi
        fi
        
        # n8n API credentials required when folder structure is enabled
        if [[ "$CONF_FOLDER_STRUCTURE" == "true" ]]; then
            if [[ -z "$CONF_N8N_BASE_URL" ]] || [[ -z "$CONF_N8N_API_KEY" ]]; then
                log ERROR "n8n API credentials are required when folder structure is enabled."
                log INFO "Please provide --n8n-url and --n8n-api-key via arguments or config file."
                show_help
                exit 1
            fi
        fi
        log DEBUG "Validating non-interactive container: $container_id"
        local found_id
        found_id=$(docker ps -q --filter "id=$container_id" --filter "name=$container_id" | head -n 1)
        if [ -z "$found_id" ]; then
             log ERROR "Container '$container_id' not found or not running."
             exit 1
        fi
        container_id=$found_id
        log SUCCESS "Using specified container: $container_id"

    else
        log DEBUG "Running in interactive mode."
        if [ -z "$action" ]; then 
            select_action
            action="$SELECTED_ACTION"
        fi
        log DEBUG "Action selected: $action"
        
        if [ -z "$container_id" ]; then
            select_container
            container_id="$SELECTED_CONTAINER_ID"
        else
            log DEBUG "Validating specified container: $container_id"
            local found_id
            found_id=$(docker ps -q --filter "id=$container_id" --filter "name=$container_id" | head -n 1)
            if [ -z "$found_id" ]; then
                 log ERROR "Container '$container_id' not found or not running."
                 log WARN "Falling back to interactive container selection..."
                 select_container
                 container_id="$SELECTED_CONTAINER_ID"
            else
                 container_id=$found_id
                 log SUCCESS "Using specified container: $container_id"
            fi
        fi
        log DEBUG "Container selected: $container_id"
        
        if [[ "$action" == "backup" ]] && ! $use_dated_backup && ! grep -q "CONF_DATED_BACKUPS=true" "${ARG_CONFIG_FILE:-$CONFIG_FILE_PATH}" 2>/dev/null; then
             printf "Create a dated backup (in a timestamped subdirectory)? (yes/no) [no]: "
             local confirm_dated
             read -r confirm_dated
             if [[ "$confirm_dated" == "yes" || "$confirm_dated" == "y" ]]; then
                 use_dated_backup=true
             fi
        fi
        log DEBUG "Use Dated Backup: $use_dated_backup"
        
        if [[ "$action" == "backup" ]] && [[ -z "$workflows_storage" && -z "$credentials_storage" ]]; then
            log INFO "Configure backup storage locations:"
            
            # Ask about workflows storage
            echo "Workflows storage:"
            echo "1) Local (secure, private)"
            echo "2) Remote (Git repository, shareable)"
            printf "Where to store workflows? (1-2) [1]: "
            read -r workflow_choice
            workflow_choice=${workflow_choice:-1}
            case "$workflow_choice" in
                1) workflows_storage="local" ;;
                2) workflows_storage="remote" ;;
                *) workflows_storage="local"; log WARN "Invalid choice, defaulting to local" ;;
            esac
            
            # Ask about credentials storage  
            echo "Credentials storage:"
            echo "1) Local (secure, recommended)"
            echo "2) Remote (Git repository, less secure)"
            printf "Where to store credentials? (1-2) [1]: "
            read -r credential_choice
            credential_choice=${credential_choice:-1}
            case "$credential_choice" in
                1) credentials_storage="local" ;;
                2) credentials_storage="remote"
                   log WARN "⚠️  You chose to store credentials in Git (less secure)" ;;
                *) credentials_storage="local"; log WARN "Invalid choice, defaulting to local" ;;
            esac
            
            log INFO "Selected: Workflows -> $workflows_storage, Credentials -> $credentials_storage"
            
            # Ask for local backup directory if either storage option is local
            if [[ "$workflows_storage" == "local" || "$credentials_storage" == "local" ]]; then
                printf "Local backup directory [~/n8n-backup]: "
                read -r custom_backup_path
                if [[ -n "$custom_backup_path" ]]; then
                    # Expand tilde if present
                    if [[ "$custom_backup_path" =~ ^~ ]]; then
                        custom_backup_path="${custom_backup_path/#\~/$HOME}"
                    fi
                    local_backup_path="$custom_backup_path"
                    log INFO "Using custom local backup directory: $local_backup_path"
                fi
            fi
            
            # Ask about n8n folder structure if workflows are going to remote
            if [[ "$workflows_storage" == "remote" ]]; then
                printf "Create n8n folder structure in Git repository? (yes/no) [no]: "
                read -r folder_structure_choice
                if [[ "$folder_structure_choice" == "yes" || "$folder_structure_choice" == "y" ]]; then
                    CONF_FOLDER_STRUCTURE="true"
                    
                    # Prompt for n8n API credentials if not already configured
                    if [[ -z "$CONF_N8N_BASE_URL" ]]; then
                        printf "n8n base URL (e.g., http://localhost:5678): "
                        read -r n8n_url
                        if [[ -n "$n8n_url" ]]; then
                            CONF_N8N_BASE_URL="$n8n_url"
                        else
                            log ERROR "n8n base URL is required for folder structure"
                            exit 1
                        fi
                    fi
                    
                    if [[ -z "$CONF_N8N_API_KEY" ]]; then
                        printf "n8n API key: "
                        read -r -s n8n_api_key
                        echo  # Add newline after hidden input
                        if [[ -n "$n8n_api_key" ]]; then
                            CONF_N8N_API_KEY="$n8n_api_key"
                        else
                            log ERROR "n8n API key is required for folder structure"
                            exit 1
                        fi
                    fi
                    
                    log INFO "✅ Folder structure enabled with n8n API integration"
                else
                    CONF_FOLDER_STRUCTURE="false"
                fi
            fi
        fi
        
        # Get GitHub config only if needed (when using remote storage or for restore)
        if [[ "$action" == "restore" ]] || [[ "$workflows_storage" == "remote" ]] || [[ "$credentials_storage" == "remote" ]]; then
            get_github_config
            github_token="$GITHUB_TOKEN"
            github_repo="$GITHUB_REPO"
            branch="$GITHUB_BRANCH"
            log DEBUG "GitHub Token: ****"
            log DEBUG "GitHub Repo: $github_repo"
            log DEBUG "GitHub Branch: $branch"
        else
            log INFO "🏠 Local-only backup - no GitHub configuration needed"
            github_token=""
            github_repo=""
            branch="main"  # Default branch for local-only operations
        fi
        
        if [[ "$action" == "restore" ]] && [[ "$restore_type" == "all" ]] && ! grep -q "CONF_RESTORE_TYPE=" "${ARG_CONFIG_FILE:-$CONFIG_FILE_PATH}" 2>/dev/null; then
            select_restore_type
            restore_type="$SELECTED_RESTORE_TYPE"
        elif [[ "$action" == "restore" ]]; then
             log INFO "Using restore type: $restore_type"
        fi
        log DEBUG "Restore Type: $restore_type"
        
        # For interactive credential restores, check if we need to ask about source preference
        if [[ "$action" == "restore" ]] && ([[ "$restore_type" == "all" ]] || [[ "$restore_type" == "credentials" ]]) && [ -t 0 ]; then
            local local_backup_dir="$HOME/n8n-backup"
            local local_credentials_file="$local_backup_dir/credentials.json"
            if [ -f "$local_credentials_file" ] && [ -s "$local_credentials_file" ]; then
                log INFO "🔒 Local secure credentials found and will be used (recommended)"
                log INFO "💡 Use --restore-type workflows to restore only workflows if desired"
            else
                log INFO "🔍 Will search for credentials in Git repository (legacy backups)"
                log INFO "💡 Consider creating a new backup to store credentials securely locally"
            fi
        fi
    fi

    # Final validation
    if [ -z "$action" ] || [ -z "$container_id" ]; then
        log ERROR "Missing required parameters (Action, Container). Exiting."
        exit 1
    fi
    
    # For remote operations, GitHub parameters are required
    local needs_github=false
    if [[ "$action" == "restore" ]] || [[ "$workflows_storage" == "remote" ]] || [[ "$credentials_storage" == "remote" ]]; then
        needs_github=true
        if [ -z "$github_token" ] || [ -z "$github_repo" ] || [ -z "$branch" ]; then
            log ERROR "Missing required GitHub parameters (Token, Repo, Branch) for remote operations. Exiting."
            exit 1
        fi
    fi

    # Perform GitHub API pre-checks only when needed
    if $needs_github; then
        if ! check_github_access "$github_token" "$github_repo" "$branch" "$action"; then
            log ERROR "GitHub access pre-checks failed. Aborting."
            exit 1
        fi
    else
        log INFO "✅ Local-only operation - skipping GitHub validation"
    fi

    # Execute action
    log INFO "Starting action: $action"
    case "$action" in
        backup)
            if backup "$container_id" "$github_token" "$github_repo" "$branch" "$use_dated_backup" "$is_dry_run" "$workflows_storage" "$credentials_storage" "$local_backup_path" "$local_rotation_limit"; then
                log SUCCESS "Backup operation completed successfully."
            else
                log ERROR "Backup operation failed."
                exit 1
            fi
            ;;
        restore)
            if restore "$container_id" "$github_token" "$github_repo" "$branch" "$restore_type" "$is_dry_run"; then
                 log SUCCESS "Restore operation completed successfully."
            else
                 log ERROR "Restore operation failed."
                 exit 1
            fi
            ;;
        *)
            log ERROR "Invalid action specified: $action. Use 'backup' or 'restore'."
            exit 1
            ;;
    esac

    exit 0
}

# --- Script Execution --- 

# Trap for unexpected errors
trap 'log ERROR "An unexpected error occurred (Line: $LINENO). Aborting."; exit 1' ERR

# Execute main function, passing all script arguments
main "$@"

exit 0

