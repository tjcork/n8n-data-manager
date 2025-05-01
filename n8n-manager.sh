#!/usr/bin/env bash
# =========================================================
# n8n-manager.sh - Interactive backup/restore for n8n
# v2.9.7 - Fixed restore functionality and file handling
# =========================================================
set -Eeuo pipefail
IFS=$\'\n\t\'

# --- Configuration ---
CONFIG_FILE_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/n8n-manager/config"

# --- Global variables ---
VERSION="2.9.7" # Fixed restore functionality and file handling
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
ARG_RESTORE_TYPE="all"
ARG_DRY_RUN=false
ARG_VERBOSE=false
ARG_LOG_FILE=""
CONF_DATED_BACKUPS=false
CONF_VERBOSE=false
CONF_LOG_FILE=""

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
                        Overrides CONF_DATED_BACKUPS in config file.
  --restore-type <type> Type of restore: 'all' (default), 'workflows', or 'credentials'.
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
    CONF_RESTORE_TYPE="all" # Optional, defaults to 'all'
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
    echo "1) Backup n8n to GitHub"
    echo "2) Restore n8n from GitHub"
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
    echo "1) All (Workflows & Credentials)"
    echo "2) Workflows Only"
    echo "3) Credentials Only"

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

    if ! echo "$scopes" | grep -qE '(^|,) *repo(,|$)'; then
        log ERROR "GitHub token is missing the required 'repo' scope."
        log INFO "Please create a new token with the 'repo' scope selected."
        return 1
    fi
    log SUCCESS "GitHub token is valid and has 'repo' scope."

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
        
        # Fixed to avoid empty command error with explicit spacing
        if $ARG_VERBOSE && [ -n "$output" ]; then
            log DEBUG "Container output:\n$(echo "$output" | sed 's/^/  /')"
        fi
        
        if [ $exit_code -ne 0 ]; then
            log ERROR "Command failed in container (Exit Code: $exit_code): $cmd"
            if ! $ARG_VERBOSE && [ -n "$output" ]; then
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

    log HEADER "Performing Backup to GitHub"
    if $is_dry_run; then log WARN "DRY RUN MODE ENABLED - NO CHANGES WILL BE MADE"; fi

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
    # Fixed potential empty command issue
    if ! dockExec "$container_id" "n8n export:workflow --all --output=$container_workflows" false; then 
        log ERROR "Failed to export workflows"
        rm -rf "$tmp_dir"; 
        return 1; 
    fi
    if ! dockExec "$container_id" "n8n export:credentials --all --decrypted --output=$container_credentials" false; then 
        log ERROR "Failed to export credentials"
        rm -rf "$tmp_dir"; 
        return 1; 
    fi
    if ! dockExec "$container_id" "printenv | grep ^N8N_ > $container_env" false; then
        log WARN "Could not capture N8N_ environment variables from container."
    fi

    # --- Determine Target Directory and Copy --- 
    local target_dir="$tmp_dir"
    local backup_timestamp=""
    if $use_dated_backup; then
        backup_timestamp="backup_$(timestamp)"
        target_dir="${tmp_dir}/${backup_timestamp}"
        log INFO "Using dated backup directory: $backup_timestamp"
        if $is_dry_run; then
            log DRYRUN "Would create directory: $target_dir"
        elif ! mkdir -p "$target_dir"; then
            log ERROR "Failed to create dated backup directory: $target_dir"
            rm -rf "$tmp_dir"
            return 1
        fi
    fi

    log INFO "Copying exported files from container into Git directory..."
    local copy_failed=false
    for file in workflows.json credentials.json .env; do
        source_file="/tmp/${file}"
        if $use_dated_backup; then
            # Create timestamped subdirectory
            mkdir -p "${target_dir}" || return 1
            dest_file="${target_dir}/${file}"
        else
            dest_file="${tmp_dir}/${file}"
        fi

        # Check if file exists in container
        if ! docker exec "$container_id" test -f "$source_file"; then
            if [[ "$file" == ".env" ]]; then
                log WARN ".env file not found in container, skipping."
                continue
            else
                log ERROR "Required file $file not found in container"
                copy_failed=true
                continue
            fi
        fi

        # Copy file from container
        size=$(docker exec "$container_id" du -h "$source_file" | awk '{print $1}')
        if ! docker cp "${container_id}:${source_file}" "${dest_file}"; then
            log ERROR "Failed to copy $file from container"
            copy_failed=true
            continue
        fi
        log SUCCESS "Successfully copied $size to ${dest_file}"
        
        # Force file uniqueness by adding a timestamp to ensure Git always sees changes
        if [[ "$file" == "workflows.json" || "$file" == "credentials.json" ]]; then
            # For JSON files: Add timestamp as a comment before the JSON content
            log DEBUG "Making $file unique with timestamp"
            mv "${dest_file}" "${dest_file}.tmp"
            echo "// n8n backup timestamp: $(date +"%Y-%m-%d %H:%M:%S.%N")" > "${dest_file}"
            cat "${dest_file}.tmp" >> "${dest_file}"
            rm "${dest_file}.tmp"
        elif [[ "$file" == ".env" ]]; then
            # For .env file: Append timestamp as a comment at the end
            log DEBUG "Making .env unique with timestamp"
            echo "" >> "${dest_file}"
            echo "# n8n backup timestamp: $(date +"%Y-%m-%d %H:%M:%S.%N")" >> "${dest_file}"
        fi
    done
    
    if $copy_failed; then rm -rf "$tmp_dir"; return 1; fi

    log INFO "Cleaning up temporary files in container..."
    dockExec "$container_id" "rm -f $container_workflows $container_credentials $container_env" "$is_dry_run" || log WARN "Could not clean up temporary files in container."

    # --- Git Commit and Push --- 
    log INFO "Adding files to Git..."
    
    if $is_dry_run; then
        if $use_dated_backup; then
            log DRYRUN "Would add dated backup directory '$backup_timestamp' to Git index"
        else
            log DRYRUN "Would add all files to Git index"
        fi
    else
        # Change to the git directory to avoid parsing issues
        cd "$tmp_dir" || { 
            log ERROR "Failed to change to git directory for add operation"; 
            rm -rf "$tmp_dir"; 
            return 1; 
        }
        
        if $use_dated_backup; then
            # For dated backups, explicitly add the backup subdirectory
            if [ -d "$backup_timestamp" ]; then
                log DEBUG "Adding dated backup directory: $backup_timestamp"
                
                # First list what's in the directory (for debugging)
                log DEBUG "Files in backup directory:"
                ls -la "$backup_timestamp" || true
                
                # Add specific directory
                if ! git add "$backup_timestamp"; then
                    log ERROR "Git add failed for dated backup directory"
                    cd - > /dev/null || true
                    rm -rf "$tmp_dir"
                    return 1
                fi
            else
                log ERROR "Dated backup directory '$backup_timestamp' not found"
                ls -la || true # Show directory contents for debugging
                cd - > /dev/null || true
                rm -rf "$tmp_dir"
                return 1
            fi
        else
            # For regular backups, add everything in the root
            log DEBUG "Adding all files to Git"
            if ! git add .; then
                log ERROR "Git add failed"
                cd - > /dev/null || true
                rm -rf "$tmp_dir"
                return 1
            fi
        fi
        
        log SUCCESS "Files added to Git successfully"
        
        # Verify that files were staged correctly
        log DEBUG "Staging status:"
        git status --short || true
    fi

    local n8n_ver
    n8n_ver=$(docker exec "$container_id" n8n --version 2>/dev/null || echo "unknown")
    log DEBUG "Detected n8n version: $n8n_ver"

    # --- Commit Logic --- 
    local commit_made=false # Flag to track if a commit was actually made
    log INFO "Committing changes..."
    
    # Create a timestamp with seconds to ensure uniqueness
    local backup_time=$(date +"%Y-%m-%d_%H-%M-%S")
    local commit_msg="🛡️ n8n Backup (v$n8n_ver) - $backup_time"
    if $use_dated_backup; then
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
    
    # Force Git to commit by adding a timestamp file to make each backup unique
    log DEBUG "Creating timestamp file to ensure backup uniqueness"
    echo "Backup generated at: $backup_time" > "./backup_timestamp.txt"
    
    # Explicitly add all n8n files AND the timestamp file
    log DEBUG "Adding all n8n files to Git..."
    if $use_dated_backup && [[ -n "$backup_timestamp" ]] && [[ -d "$backup_timestamp" ]]; then
        log DEBUG "Adding dated backup directory: $backup_timestamp"
        git add "$backup_timestamp" ./backup_timestamp.txt || {
            log ERROR "Failed to add dated backup directory"
            git status
        }
    else
        # Add individual files explicitly to ensure nothing is missed
        log DEBUG "Adding individual files to Git"
        git add .env credentials.json workflows.json ./backup_timestamp.txt || {
            log ERROR "Failed to add n8n files"
            git status
        }
    fi
    
    # Skip Git's change detection and always commit
    log DEBUG "Committing backup with message: $commit_msg"
    if $is_dry_run; then
        log DRYRUN "Would commit with message: $commit_msg"
        commit_made=true # Assume commit would happen in dry run
    else
        # Force the commit with --allow-empty to ensure it happens
        if git commit --allow-empty -m "$commit_msg" 2>/dev/null; then
            commit_made=true # Set flag to indicate commit success
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
    
    if $is_dry_run; then
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
    
    log SUCCESS "Backup successfully pushed to GitHub repository"
    cd - > /dev/null || true

    log INFO "Cleaning up host temporary directory..."
    if $is_dry_run; then
        log DRYRUN "Would remove temporary directory: $tmp_dir"
    else
        rm -rf "$tmp_dir"
    fi

    log SUCCESS "Backup successfully completed and pushed to GitHub."
    if $is_dry_run; then log WARN "(Dry run mode was active)"; fi
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

    if [ -t 0 ] && ! $is_dry_run; then
        log WARN "This will overwrite existing data (type: $restore_type)."
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
    log INFO "Exporting current n8n data for backup..."
    if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
        if ! dockExec "$container_id" "n8n export:workflow --all --output=$container_pre_workflows" false; then backup_failed=true; fi
    fi
    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
        if ! $backup_failed; then
            if ! dockExec "$container_id" "n8n export:credentials --all --decrypted --output=$container_pre_credentials" false; then backup_failed=true; fi
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
    
    # Look for backup files in the repository using a broader search
    log INFO "Searching for backup files in the repository..."
    
    # Find all JSON files in the repository to identify potential backups
    local workflow_files=()
    local credential_files=()
    
    # First look in the repository root
    if [ -f "${download_dir}/workflows.json" ]; then
        workflow_files+=("${download_dir}/workflows.json")
        log DEBUG "Found workflows.json in repository root"
    fi
    
    if [ -f "${download_dir}/credentials.json" ]; then
        credential_files+=("${download_dir}/credentials.json")
        log DEBUG "Found credentials.json in repository root"
    fi
    
    # Look for any JSON files that might be our backup files
    while IFS= read -r file; do
        if [[ "$file" =~ workflows\.json$ ]]; then
            workflow_files+=("$file")
            log DEBUG "Found workflow file: $file"
        elif [[ "$file" =~ credentials\.json$ ]]; then
            credential_files+=("$file")
            log DEBUG "Found credentials file: $file"
        fi
    done < <(find "$download_dir" -type f -name "*.json" 2>/dev/null)
    
    # Remove timestamp comments from JSON files if present
    local clean_files=false
    if [ ${#workflow_files[@]} -gt 0 ] || [ ${#credential_files[@]} -gt 0 ]; then
        log INFO "Cleaning timestamp comments from JSON files..."
        clean_files=true
        
        # Function to clean a JSON file by removing timestamp comments
        clean_json_file() {
            local file=$1
            local output_file=$2
            log DEBUG "Cleaning file: $file -> $output_file"
            
            # If the file starts with a timestamp comment, remove it
            if grep -q "^// n8n backup timestamp:" "$file"; then
                tail -n +2 "$file" > "$output_file"
                log DEBUG "Removed timestamp comment from $file"
            else
                # Just copy the file if no timestamp
                cp "$file" "$output_file"
            fi
        }
    fi
    
    # Set the paths to the downloaded files based on if we're using a dated backup
    local downloaded_workflows=""
    local downloaded_credentials=""
    local temp_dir="${download_dir}/temp"
    mkdir -p "$temp_dir"
    
    # Choose which files to use based on dated backup selection
    if $dated_backup_found; then
        local dated_path="${selected_backup#./}"
        log INFO "Looking for files in dated backup: $dated_path"
        
        # Check if dated backup contains the files
        for wf in "${workflow_files[@]}"; do
            if [[ "$wf" == *"$dated_path/workflows.json" ]]; then
                downloaded_workflows="${temp_dir}/workflows.json"
                if $clean_files; then
                    clean_json_file "$wf" "$downloaded_workflows"
                else
                    cp "$wf" "$downloaded_workflows"
                fi
                log INFO "Using workflow file from dated backup: $wf"
                break
            fi
        done
        
        for cf in "${credential_files[@]}"; do
            if [[ "$cf" == *"$dated_path/credentials.json" ]]; then
                downloaded_credentials="${temp_dir}/credentials.json"
                if $clean_files; then
                    clean_json_file "$cf" "$downloaded_credentials"
                else
                    cp "$cf" "$downloaded_credentials"
                fi
                log INFO "Using credentials file from dated backup: $cf"
                break
            fi
        done
    else
        # Use files from the repository root if available
        log INFO "Using files from repository root"
        
        # Try the repository root first
        if [ -f "${download_dir}/workflows.json" ]; then
            downloaded_workflows="${temp_dir}/workflows.json"
            if $clean_files; then
                clean_json_file "${download_dir}/workflows.json" "$downloaded_workflows"
            else
                cp "${download_dir}/workflows.json" "$downloaded_workflows"
            fi
            log INFO "Using workflows.json from repository root"
        # If not in root, use the first workflow file found
        elif [ ${#workflow_files[@]} -gt 0 ]; then
            downloaded_workflows="${temp_dir}/workflows.json"
            if $clean_files; then
                clean_json_file "${workflow_files[0]}" "$downloaded_workflows"
            else
                cp "${workflow_files[0]}" "$downloaded_workflows"
            fi
            log INFO "Using workflow file: ${workflow_files[0]}"
        fi
        
        if [ -f "${download_dir}/credentials.json" ]; then
            downloaded_credentials="${temp_dir}/credentials.json"
            if $clean_files; then
                clean_json_file "${download_dir}/credentials.json" "$downloaded_credentials"
            else
                cp "${download_dir}/credentials.json" "$downloaded_credentials"
            fi
            log INFO "Using credentials.json from repository root"
        # If not in root, use the first credentials file found
        elif [ ${#credential_files[@]} -gt 0 ]; then
            downloaded_credentials="${temp_dir}/credentials.json"
            if $clean_files; then
                clean_json_file "${credential_files[0]}" "$downloaded_credentials"
            else
                cp "${credential_files[0]}" "$downloaded_credentials"
            fi
            log INFO "Using credentials file: ${credential_files[0]}"
        fi
    fi
    
    # Verify that the files exist
    local files_found=true
    
    if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
        if [ ! -f "$downloaded_workflows" ]; then
            log ERROR "workflows.json not found in selected backup location."
            files_found=false
        else
            log DEBUG "Workflow file size: $(du -h "$downloaded_workflows" | cut -f1)"
        fi
    fi
    
    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
        if [ ! -f "$downloaded_credentials" ]; then
            log ERROR "credentials.json not found in selected backup location."
            files_found=false
        else
            log DEBUG "Credentials file size: $(du -h "$downloaded_credentials" | cut -f1)"
        fi
    fi

    if ! $files_found; then
        log ERROR "Required backup files not found in repository."
        log DEBUG "Here are all the files in the repository:"
        find "$download_dir" -type f | sort || true
        rm -rf "$download_dir"
        if [ -n "$pre_restore_dir" ]; then log WARN "Pre-restore backup kept at: $pre_restore_dir"; fi
        return 1
    fi
    log SUCCESS "Backup files downloaded successfully from GitHub."

    # --- 3. Import into Container --- 
    log HEADER "Step 3: Importing Data into n8n Container"
    local container_import_workflows="/tmp/import_workflows.json"
    local container_import_credentials="/tmp/import_credentials.json"
    local import_failed=false

    log INFO "Copying downloaded files to container..."
    local copy_failed=false
    if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
        if $is_dry_run; then
            log DRYRUN "Would copy $downloaded_workflows to ${container_id}:${container_import_workflows}"
        elif ! docker cp "$downloaded_workflows" "${container_id}:${container_import_workflows}"; then
            log ERROR "Failed to copy workflows.json to container."
            copy_failed=true
        fi
    fi
    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
        if $is_dry_run; then
            log DRYRUN "Would copy $downloaded_credentials to ${container_id}:${container_import_credentials}"
        elif ! docker cp "$downloaded_credentials" "${container_id}:${container_import_credentials}"; then
            log ERROR "Failed to copy credentials.json to container."
            copy_failed=true
        fi
    fi
    if $copy_failed; then
        dockExec "$container_id" "rm -f $container_import_workflows $container_import_credentials" "$is_dry_run" || true
        import_failed=true
    fi

    if ! $import_failed; then
        log INFO "Importing data into n8n (this may take a moment)..."
        if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
            if ! dockExec "$container_id" "n8n import:workflow --separate --input=$container_import_workflows" "$is_dry_run"; then
                log ERROR "Failed to import workflows."
                import_failed=true
            fi
        fi
        if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
            if ! dockExec "$container_id" "n8n import:credentials --separate --input=$container_import_credentials" "$is_dry_run"; then
                log ERROR "Failed to import credentials."
                import_failed=true
            fi
        fi
    fi

    log INFO "Cleaning up import files in container..."
    dockExec "$container_id" "rm -f $container_import_workflows $container_import_credentials" "$is_dry_run" || log WARN "Could not clean up import files in container."

    # --- 4. Handle Results & Rollback --- 
    log HEADER "Step 4: Finalizing Restore"
    if $is_dry_run; then
        log DRYRUN "Would remove download directory: $download_dir"
    else
        rm -rf "$download_dir"
    fi

    if $import_failed; then
        log ERROR "Restore failed during import process."
        if [ -n "$pre_restore_dir" ]; then
            if ! rollback_restore "$container_id" "$pre_restore_dir" "$restore_type" "$is_dry_run"; then
                return 1
            else
                if $is_dry_run; then
                    log DRYRUN "Would remove pre-restore backup directory: $pre_restore_dir"
                else
                    rm -rf "$pre_restore_dir"
                fi
                return 1
            fi
        else
            log ERROR "No pre-restore backup was available. Cannot rollback."
            return 1
        fi
    else
        log SUCCESS "Restore completed successfully!"
        if [ -n "$pre_restore_dir" ]; then
            log INFO "Cleaning up pre-restore backup directory..."
            if $is_dry_run; then
                log DRYRUN "Would remove pre-restore backup directory: $pre_restore_dir"
            else
                rm -rf "$pre_restore_dir"
            fi
        fi
        if $is_dry_run; then log WARN "(Dry run mode was active)"; fi
        return 0
    fi
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
            --restore-type) 
                if [[ "$2" == "all" || "$2" == "workflows" || "$2" == "credentials" ]]; then
                    ARG_RESTORE_TYPE="$2"
                else
                    echo -e "${RED}[ERROR]${NC} Invalid --restore-type: '$2'. Must be 'all', 'workflows', or 'credentials'." >&2
                    exit 1
                fi
                shift 2 ;;
            --dry-run) ARG_DRY_RUN=true; shift 1 ;; 
            --verbose) ARG_VERBOSE=true; shift 1 ;; 
            --log-file) ARG_LOG_FILE="$2"; shift 2 ;; 
            --trace) DEBUG_TRACE=true; shift 1;; 
            -h|--help) show_help; exit 0 ;; 
            *) echo -e "${RED}[ERROR]${NC} Invalid option: $1" >&2; show_help; exit 1 ;; 
        esac
    done

    # Load config file (must happen after parsing args)
    load_config

    log HEADER "n8n Backup/Restore Manager v$VERSION"
    if $ARG_DRY_RUN; then log WARN "DRY RUN MODE ENABLED"; fi
    if $ARG_VERBOSE; then log DEBUG "Verbose mode enabled."; fi
    
    check_host_dependencies

    # Use local variables within main
    local action="$ARG_ACTION"
    local container_id="$ARG_CONTAINER"
    local github_token="$ARG_TOKEN"
    local github_repo="$ARG_REPO"
    local branch="${ARG_BRANCH:-main}"
    local use_dated_backup=$ARG_DATED_BACKUPS
    local restore_type="${ARG_RESTORE_TYPE:-all}"
    local is_dry_run=$ARG_DRY_RUN

    log DEBUG "Initial Action: $action"
    log DEBUG "Initial Container: $container_id"
    log DEBUG "Initial Repo: $github_repo"
    log DEBUG "Initial Branch: $branch"
    log DEBUG "Initial Dated Backup: $use_dated_backup"
    log DEBUG "Initial Restore Type: $restore_type"
    log DEBUG "Initial Dry Run: $is_dry_run"
    log DEBUG "Initial Verbose: $ARG_VERBOSE"
    log DEBUG "Initial Log File: $ARG_LOG_FILE"

    # Check if running non-interactively
    if ! [ -t 0 ]; then
        log DEBUG "Running in non-interactive mode."
        if { [ -z "$action" ] || [ -z "$container_id" ] || [ -z "$github_token" ] || [ -z "$github_repo" ]; }; then
            log ERROR "Running in non-interactive mode but required parameters are missing."
            log INFO "Please provide --action, --container, --token, and --repo via arguments or config file."
            show_help
            exit 1
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
        
        get_github_config
        github_token="$GITHUB_TOKEN"
        github_repo="$GITHUB_REPO"
        branch="$GITHUB_BRANCH"
        log DEBUG "GitHub Token: ****"
        log DEBUG "GitHub Repo: $github_repo"
        log DEBUG "GitHub Branch: $branch"
        
        if [[ "$action" == "backup" ]] && ! $use_dated_backup && ! grep -q "CONF_DATED_BACKUPS=true" "${ARG_CONFIG_FILE:-$CONFIG_FILE_PATH}" 2>/dev/null; then
             printf "Create a dated backup (in a timestamped subdirectory)? (yes/no) [no]: "
             local confirm_dated
             read -r confirm_dated
             if [[ "$confirm_dated" == "yes" || "$confirm_dated" == "y" ]]; then
                 use_dated_backup=true
             fi
        fi
        log DEBUG "Use Dated Backup: $use_dated_backup"
        
        if [[ "$action" == "restore" ]] && [[ "$restore_type" == "all" ]] && ! grep -q "CONF_RESTORE_TYPE=" "${ARG_CONFIG_FILE:-$CONFIG_FILE_PATH}" 2>/dev/null; then
            select_restore_type
            restore_type="$SELECTED_RESTORE_TYPE"
        elif [[ "$action" == "restore" ]]; then
             log INFO "Using restore type: $restore_type"
        fi
        log DEBUG "Restore Type: $restore_type"
    fi

    # Final validation
    if [ -z "$action" ] || [ -z "$container_id" ] || [ -z "$github_token" ] || [ -z "$github_repo" ] || [ -z "$branch" ]; then
        log ERROR "Missing required parameters (Action, Container, Token, Repo, Branch). Exiting."
        exit 1
    fi

    # Perform GitHub API pre-checks (skip in dry run? No, checks are read-only)
    if ! check_github_access "$github_token" "$github_repo" "$branch" "$action"; then
        log ERROR "GitHub access pre-checks failed. Aborting."
        exit 1
    fi

    # Execute action
    log INFO "Starting action: $action"
    case "$action" in
        backup)
            if backup "$container_id" "$github_token" "$github_repo" "$branch" "$use_dated_backup" "$is_dry_run"; then
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

