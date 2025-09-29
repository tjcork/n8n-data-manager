#!/usr/bin/env bash
# =========================================================
# lib/interactive.sh - Interactive UI functions for n8n-manager
# =========================================================
# All interactive user interface functions: selection menus,
# configuration prompts, and user interaction handling

# Source common utilities
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

show_config_summary() {
    log INFO "📋 Current Configuration:"
    
    # Backup configuration - use numeric system if available
    local workflows_desc="not set"
    local credentials_desc="not set"
    
    # Determine workflows description from numeric value
    if [[ -n "${workflows:-}" ]]; then
        case "$workflows" in
            0) workflows_desc="disabled" ;;
            1) workflows_desc="local secure storage" ;;
            2) 
                if [[ "${folder_structure_enabled:-false}" == "true" ]] || [[ "$folder_structure" == "true" ]]; then
                    workflows_desc="remote Git repository (with n8n folder structure)"
                else
                    workflows_desc="remote Git repository"
                fi
                ;;
        esac
    fi
    
    # Determine credentials description from numeric value  
    if [[ -n "${credentials:-}" ]]; then
        case "$credentials" in
            0) credentials_desc="disabled" ;;
            1) credentials_desc="local secure storage (recommended)" ;;
            2) credentials_desc="remote Git repository (security risk!)" ;;
        esac
    fi
    
    log INFO "   📄 Workflows: $workflows_desc"
    log INFO "   🔒 Credentials: $credentials_desc"
    
    if [[ -n "$github_repo" ]]; then
        log INFO "   📚 GitHub: $github_repo (branch: ${github_branch:-main})"
    fi

    if [[ -n "${git_commit_name:-}" || -n "${git_commit_email:-}" ]]; then
        local display_name display_email
        display_name="${git_commit_name:-N8N Backup Manager}"
        display_email="${git_commit_email:-backup@n8n.local}"
        log INFO "   ✍️ Git identity: $display_name <$display_email>"
    fi
    
    if [[ -n "$n8n_api_key" ]]; then
        log INFO "   🔐 n8n API auth: API key configured"
    elif [[ -n "$n8n_session_credential" ]]; then
        log INFO "   🔐 n8n session credential: $n8n_session_credential"
    elif [[ -n "$n8n_email" || -n "$n8n_password" ]]; then
        log INFO "   🔐 n8n session login: direct email/password (legacy)"
    fi

    if [[ "${dated_backups_flag:-false}" == "true" ]] || [[ "$dated_backups" == "true" ]]; then
        log INFO "   📅 Timestamped backups: enabled"
    else
        log INFO "   📅 Timestamped backups: disabled"
    fi
    
    # Check if local storage is needed (when workflows=1 or credentials=1)
    if [[ "${needs_local_path:-}" == "true" ]] || [[ "$workflows" == "1" ]] || [[ "$credentials" == "1" ]]; then
        log INFO "   💾 Local path: $local_backup_path"
        if [[ "$local_rotation_limit" == "0" ]]; then
            log INFO "   🔄 Local rotation: overwrite mode"
        elif [[ "$local_rotation_limit" == "unlimited" ]]; then
            log INFO "   🔄 Local rotation: keep all"
        else
            log INFO "   🔄 Local rotation: keep $local_rotation_limit most recent"
        fi
    fi
    echo
}

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Automated backup and restore tool for n8n Docker containers using GitHub.
Reads configuration from local 'config' file, then ~/.config/n8n-manager/config if it exists.

Options:
  --action <action>     Action to perform: 'backup' or 'restore'.
  --container <id|name> Target Docker container ID or name.
  --token <pat>         GitHub Personal Access Token (PAT).
  --repo <user/repo>    GitHub repository (e.g., 'myuser/n8n-backup').
  --branch <branch>     GitHub branch to use (defaults to 'main').
  --dated               Create timestamped subdirectory for backups (e.g., YYYY-MM-DD_HH-MM-SS/).
  --workflows [mode]    Include workflows in backup. Mode: 0 (disabled), 1 (local, default), 2 (remote Git repo).
  --credentials [mode]  Include credentials in backup. Mode: 0 (disabled), 1 (local, default), 2 (remote Git repo).
  --path <path>         Local backup directory path (defaults to '~/n8n-backup').
  --rotation <limit>    Local backup rotation: '0' (overwrite), number (keep N most recent), 'unlimited' (keep all).
  --folder-structure    Enable n8n folder structure mirroring in Git (requires API access).
  --n8n-url <url>       n8n instance URL (e.g., 'http://localhost:5678').
  --n8n-api-key <key>   n8n API key for folder structure access.
    --n8n-cred <name>   n8n credential name providing Basic Auth for session login when API key is absent.
  --restore-type <type> Type of restore: 'all' (default), 'workflows', or 'credentials' (legacy).
                        Overrides RESTORE_TYPE in config file.
  --dry-run             Simulate the action without making any changes.
  --verbose             Enable detailed debug logging.
  --log-file <path>     Path to a file to append logs to.
  --config <path>       Path to a custom configuration file.
  -h, --help            Show this help message and exit.

Configuration Files (checked in order):
  1. ./.config (local, project-specific)
  2. ~/.config/n8n-manager/config (user-specific)
  3. Custom path via --config option

  Define variables like:
    # === REQUIRED SETTINGS ===
    # GitHub Personal Access Token for repository access
    GITHUB_TOKEN="ghp_1234567890abcdef1234567890abcdef12345678"
    
    # GitHub repository in format: username/repository
    GITHUB_REPO="myuser/n8n-backup"
    
    # Default container ID or name to backup/restore
    DEFAULT_CONTAINER="n8n-container-name"
    
    # === OPTIONAL GITHUB SETTINGS ===
    # GitHub branch to use (defaults to 'main')
    GITHUB_BRANCH="main"
    
    # === BACKUP BEHAVIOR SETTINGS ===
    # Create timestamped backup directories (true/false, defaults to false)
    DATED_BACKUPS=true
    
    # Workflows storage: 0=disabled, 1=local, 2=remote (Git repo)
    WORKFLOWS=1
    
    # Credentials storage: 0=disabled, 1=local (secure), 2=remote (Git repo)
    CREDENTIALS=1
    
    # === LOCAL BACKUP SETTINGS ===
    # Custom local backup directory path (defaults to ~/n8n-backup)
    LOCAL_BACKUP_PATH="/custom/backup/path"
    
    # Local backup rotation: 0 (overwrite), number (keep N), "unlimited" (keep all)
    LOCAL_ROTATION_LIMIT="10"
    
    # === n8n FOLDER STRUCTURE SETTINGS ===
    # Enable n8n folder structure mirroring in Git (requires n8n API access)
    FOLDER_STRUCTURE=false
    
    # n8n instance URL (required if FOLDER_STRUCTURE=true)
    N8N_BASE_URL="http://localhost:5678"
    
    # n8n API key for folder structure access (required if FOLDER_STRUCTURE=true)
    N8N_API_KEY="n8n_api_1234567890abcdef1234567890abcdef"

    # n8n credential name for session-based login (alternative to API key)
    # Example: Basic Auth credential named "N8N REST BACKUP"
    N8N_LOGIN_CREDENTIAL_NAME="N8N REST BACKUP"
    
    # === RESTORE BEHAVIOR SETTINGS ===
    # Default restore type: "all", "workflows", or "credentials" (defaults to 'all')
    RESTORE_TYPE="all"
    
    # === LOGGING SETTINGS ===
    # Enable verbose debug logging (true/false, defaults to false)
    VERBOSE=false
    
    # Enable dry run mode - simulate actions without making changes (true/false, defaults to false)
    DRY_RUN=false
    
    # Path to log file for persistent logging (optional)
    LOG_FILE="/var/log/n8n-manager.log"

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

        if [ -n "$default_container" ] && { [ "$id" = "$default_container" ] || [ "$name" = "$default_container" ]; }; then
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
    
    # Show current configuration summary
    show_config_summary
    
    echo "1) Backup n8n - Use current configuration"
    echo "2) Restore n8n - Use current configuration" 
    echo "3) Reconfigure - Reset and configure interactively"
    echo "4) Quit"

    local choice
    while true; do
        printf "\nSelect an option (1-4): "
        read -r choice
        case "$choice" in
            1) SELECTED_ACTION="backup"; return ;; 
            2) SELECTED_ACTION="restore"; return ;;
            3) SELECTED_ACTION="reconfigure"; return ;;
            4) log INFO "Exiting..."; exit 0 ;; 
            *) log ERROR "Invalid option. Please select 1, 2, 3, or 4." ;; 
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
    local reconfigure_mode="${1:-false}"
    local local_token="$github_token"
    local local_repo="$github_repo"
    local local_branch="$github_branch"

    log HEADER "GitHub Configuration"

    # Re-ask for token if not set or in reconfigure mode
    while [[ -z "$local_token" ]] || [[ "$reconfigure_mode" == "true" ]]; do
        printf "Enter GitHub Personal Access Token (PAT): "
        read -s local_token
        echo
        if [ -z "$local_token" ]; then 
            log ERROR "GitHub token is required."
        else
            break  # Exit loop once we have a valid token
        fi
    done

    # Re-ask for repo if not set or in reconfigure mode
    while [[ -z "$local_repo" ]] || [[ "$reconfigure_mode" == "true" ]]; do
        printf "Enter GitHub repository (format: username/repo): "
        read -r local_repo
        if [ -z "$local_repo" ] || ! echo "$local_repo" | grep -q "/"; then
            log ERROR "Invalid GitHub repository format. It should be 'username/repo'."
            local_repo=""
        else
            break  # Exit loop once we have a valid repo
        fi
    done

    # Re-ask for branch if not set or in reconfigure mode
    if [[ -z "$local_branch" ]] || [[ "$reconfigure_mode" == "true" ]]; then
         printf "Enter Branch to use [main]: "
         read -r local_branch
         local_branch=${local_branch:-main}
    else
        log INFO "Using branch: $local_branch"
    fi

    github_token="$local_token"
    github_repo="$local_repo"
    github_branch="$local_branch"
}

# Select workflows backup mode (0=disabled, 1=local, 2=remote)
select_workflows_storage() {
    log HEADER "Choose Workflows Backup Mode"
    echo "0) Disabled - Skip workflow backup entirely"
    echo "1) Local Storage - Store workflows in secure local storage (recommended)"
    echo "2) Remote Storage - Store workflows in Git repository (shareable but less secure)"
    echo
    
    local choice
    while true; do
        printf "Select workflows backup mode (0-2) [default: 1]: "
        read -r choice
        choice=${choice:-1}
        case "$choice" in
            0) workflows=0; log INFO "Workflows backup: (0) disabled"; return ;;
            1) workflows=1; log INFO "Workflows backup: (1) local"; return ;;
            2) workflows=2; log INFO "Workflows backup: (2) remote"; return ;;
            *) echo "Invalid choice. Please enter 0, 1, or 2." ;;
        esac
    done
}

# Select credentials backup mode (0=disabled, 1=local, 2=remote)  
select_credentials_storage() {
    log HEADER "Choose Credentials Backup Mode"
    echo "0) Disabled - Skip credential backup entirely"
    echo "1) Local Storage - Store credentials in secure local storage (RECOMMENDED)"
    echo "2) Remote Storage - Store credentials in Git repository (NOT RECOMMENDED - security risk)"
    echo
    echo "⚠️  WARNING: Option 2 stores sensitive credentials in Git repository!"
    echo "   This may expose passwords, API keys, and other secrets."
    echo "   Only use option 2 if you understand and accept this security risk."
    echo
    
    local choice
    while true; do
        printf "Select credentials backup mode (0-2) [default: 1]: "
        read -r choice
        choice=${choice:-1}
        case "$choice" in
            0) credentials=0; log INFO "Credentials backup: (0) disabled"; return ;;
            1) credentials=1; log INFO "Credentials backup: (1) local"; return ;;
            2) 
                log WARN "You selected REMOTE STORAGE for credentials!"
                printf "Are you sure you want to store credentials in Git? (y/N): "
                read -r confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    credentials=2
                    log WARN "Credentials backup: (2) remote (less secure)"
                    return
                else
                    log INFO "Staying with secure local storage."
                    credentials=1
                    return
                fi
                ;;
            *) echo "Invalid choice. Please enter 0, 1, or 2." ;;
        esac
    done
}