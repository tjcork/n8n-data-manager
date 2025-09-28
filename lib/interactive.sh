#!/usr/bin/env bash
# =========================================================
# lib/interactive.sh - Interactive UI functions for n8n-manager
# =========================================================
# All interactive user interface functions: selection menus,
# configuration prompts, and user interaction handling

# Source common utilities
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

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