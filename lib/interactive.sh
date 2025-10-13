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
    local environment_desc="not set"
    
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

    if [[ -n "${environment:-}" ]]; then
        case "$environment" in
            0) environment_desc="disabled" ;;
            1) environment_desc="local secure storage" ;;
            2) environment_desc="remote Git repository (high risk)" ;;
        esac
    fi
    
    log INFO "   📄 Workflows: $workflows_desc"
    log INFO "   🔒 Credentials: $credentials_desc"
    log INFO "   🌱 Environment: $environment_desc"
    log INFO "   🏷️ Default project: ${project_name:-Personal}"

    local effective_prefix
    effective_prefix="$(effective_repo_prefix)"
    if [[ -n "$effective_prefix" ]]; then
        log INFO "   🗂️ GitHub path prefix: $effective_prefix"
    else
        log INFO "   🗂️ GitHub path prefix: <repository root>"
    fi

    if [[ "${n8n_path_source:-default}" != "default" && "${n8n_path_source:-unset}" != "unset" ]]; then
        if [[ -n "$n8n_path" ]]; then
            log INFO "   🧭 N8N path hint: $n8n_path (source: $n8n_path_source)"
        else
            log INFO "   🧭 N8N path hint: <repository root> (source: $n8n_path_source)"
        fi
    elif [[ -n "$github_path" && "${github_path_source:-default}" != "default" ]]; then
        : # explicit GitHub path already shown above
    elif [[ -z "$github_path" && -n "$n8n_path" ]]; then
        # maintain visibility of default hint when explicitly set but treated as default
        log INFO "   🧭 N8N path hint: $n8n_path"
    fi
    
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
        log INFO "   🔐 n8n session login: direct email/password"
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
  --action <action>       Action to perform: 'backup', 'restore', or 'configure'.
  --container <id|name>   Target Docker container ID or name.
  --token <pat>           GitHub Personal Access Token (PAT).
  --repo <user/repo>      GitHub repository (e.g., 'myuser/n8n-backup').
  --branch <branch>       GitHub branch to use (defaults to 'main').
  --dated                 Create timestamped subdirectory for backups (e.g., YYYY-MM-DD_HH-MM-SS/).
  --workflows [mode]      Include workflows in backup. Mode: 0 (disabled), 1 (local, default), 2 (remote Git repo).
  --credentials [mode]    Include credentials in backup. Mode: 0 (disabled), 1 (local, default), 2 (remote Git repo).
  --environment [mode]    Include environment variables. Mode: 0 (disabled, default), 1 (local), 2 (remote Git repo).
  --github-path <path>    Organize Git-backed files under the given repository subdirectory (defaults to project name).
  --local-path <path>     Local backup directory path (defaults to '~/n8n-backup').
  --decrypt <true|false>  If true, export credentials decrypted from n8n (not recommended, less secure).
                          Defaults to false to ensure encrypted credential exports.
  --rotation <limit>      Local backup rotation: '0' (overwrite), number (keep N most recent), 'unlimited' (keep all).
  --folder-structure      Enable n8n folder structure mirroring in Git (requires credential access).
  --n8n-url <url>         n8n instance URL (e.g., 'http://localhost:5678').
  --n8n-api-key <key>     n8n API key for folder structure access.
  --n8n-cred <name>       n8n credential name providing Basic Auth for session login when API key is absent.
  --preserve              Force reuse of workflow IDs when restoring structured exports (default: false; otherwise IDs are reused only when safe).
  --no-overwrite          Force new workflow IDs on import (clears IDs even if --preserve is set).
  --dry-run               Simulate the action without making any changes.
  --defaults              Assume defaults for any missing inputs (non-interactive automation).
  --verbose               Enable detailed debug logging.
  --log-file <path>       Path to a file to append logs to.
  --config <path>         Path to a custom configuration file.
  -h, --help              Show this help message and exit.

Configuration Files (checked in order):
  1. ./.config (local, project-specific)
  2. ~/.config/n8n-manager/config (user-specific)
  3. Custom path via --config option

Run with action 'configure' to deploy or update the configuration file interactively.

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
    echo "3) Configure config file - Create/update interactively"
    echo "4) Interactive - Execute with specific configuration"
    echo "5) Quit"

    local choice
    while true; do
        printf "\nSelect an option (1-5): "
        read -r choice
        case "$choice" in
            1) SELECTED_ACTION="backup"; return ;; 
            2) SELECTED_ACTION="restore"; return ;;
            3) SELECTED_ACTION="configure"; return ;;
            4) SELECTED_ACTION="reconfigure"; return ;;
            5) log INFO "Exiting..."; exit 0 ;; 
            *) log ERROR "Invalid option. Please select 1, 2, 3, 4, or 5." ;; 
        esac
    done
}

select_restore_type() {
    log HEADER "Choose Restore Components"

    local local_backup_dir="$HOME/n8n-backup"
    local local_workflows_file="$local_backup_dir/workflows.json"
    local local_credentials_file="$local_backup_dir/credentials.json"

    local workflows_default="${RESTORE_WORKFLOWS_MODE:-${restore_workflows_mode:-2}}"
    local credentials_default="${RESTORE_CREDENTIALS_MODE:-${restore_credentials_mode:-1}}"
    local folder_structure_default="${RESTORE_APPLY_FOLDER_STRUCTURE:-${restore_folder_structure_preference:-auto}}"
    local workflows_choice=""
    local credentials_choice=""

    while true; do
        echo "Workflows restore mode:"
        echo "0) Disabled - Skip workflow restore"
        echo "1) Local Storage - Restore from local backup ($local_workflows_file)"
        echo "2) Remote Storage - Restore from Git repository"
        printf "\nSelect workflows restore mode (0-2) [default: %s]: " "$workflows_default"
        read -r workflows_choice
        workflows_choice=${workflows_choice:-$workflows_default}
        case "$workflows_choice" in
            0|1|2) : ;; 
            *) log ERROR "Invalid option. Please enter 0, 1, or 2."; continue ;;
        esac

        echo
        echo "Credentials restore mode:"
        echo "0) Disabled - Skip credential restore"
        echo "1) Local Secure Storage - Restore from local backup ($local_credentials_file)"
        echo "2) Remote Storage - Restore from Git repository"
        printf "\nSelect credentials restore mode (0-2) [default: %s]: " "$credentials_default"
        read -r credentials_choice
        credentials_choice=${credentials_choice:-$credentials_default}
        case "$credentials_choice" in
            0|1|2) : ;;
            *) log ERROR "Invalid option. Please enter 0, 1, or 2."; echo; continue ;;
        esac

        if [[ "$workflows_choice" == "0" && "$credentials_choice" == "0" ]]; then
            log WARN "At least one component must be selected for restore."
            echo
            continue
        fi

        break
    done

    RESTORE_WORKFLOWS_MODE="$workflows_choice"
    RESTORE_CREDENTIALS_MODE="$credentials_choice"

    if [[ "$RESTORE_WORKFLOWS_MODE" != "0" && "$RESTORE_CREDENTIALS_MODE" != "0" ]]; then
        SELECTED_RESTORE_TYPE="all"
    elif [[ "$RESTORE_WORKFLOWS_MODE" != "0" ]]; then
        SELECTED_RESTORE_TYPE="workflows"
    else
        SELECTED_RESTORE_TYPE="credentials"
    fi

    if [[ "$RESTORE_WORKFLOWS_MODE" == "2" ]]; then
        case "$folder_structure_default" in
            true) RESTORE_APPLY_FOLDER_STRUCTURE="true" ;;
            skip) RESTORE_APPLY_FOLDER_STRUCTURE="skip" ;;
            auto) RESTORE_APPLY_FOLDER_STRUCTURE="auto" ;;
            *) RESTORE_APPLY_FOLDER_STRUCTURE="auto" ;;
        esac
    else
        RESTORE_APPLY_FOLDER_STRUCTURE="skip"
    fi

    log INFO "Selected restore configuration: Workflows=($RESTORE_WORKFLOWS_MODE) $(format_storage_value $RESTORE_WORKFLOWS_MODE), Credentials=($RESTORE_CREDENTIALS_MODE) $(format_storage_value $RESTORE_CREDENTIALS_MODE)"
}

select_credential_source() {
    local local_file="$1"
    local git_file="$2"
    local selected_source=""
    
    log HEADER "Multiple Credential Sources Found"
    log INFO "Both local and Git repository credentials are available."
    echo "1) Local Storage"
    echo "   📍 $local_file"
    echo "   🔒 Stored securely with proper file permissions"
    echo "2) Git Repository"
    echo "   📍 $git_file"
    echo "   ⚠️  Ensure to maintain encryption for security - credentials stored in Git history"
    
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
    local restore_scope="$1"
    local github_repo="$2"
    local branch="$3"
    local workflows_mode="${4:-${RESTORE_WORKFLOWS_MODE:-2}}"
    local credentials_mode="${5:-${RESTORE_CREDENTIALS_MODE:-1}}"

    log HEADER "📋 Restore Plan"
    if [[ -n "$github_repo" ]]; then
        log INFO "Repository: $github_repo (branch: $branch)"
    fi

    case "$workflows_mode" in
        0) log INFO "📄 Workflows: Will remain unchanged" ;;
        1) log INFO "📄 Workflows: Will be restored from local backup (~/.n8n-backup/workflows.json)" ;;
        2) log INFO "� Workflows: Will be restored from Git repository" ;;
    esac

    case "$credentials_mode" in
        0) log INFO "🔒 Credentials: Will remain unchanged" ;;
        1) log INFO "🔒 Credentials: Will be restored from local secure storage (~/.n8n-backup/credentials.json)" ;;
        2) log INFO "� Credentials: Will be restored from Git repository" ;;
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

prompt_default_container() {
    local current_default="${default_container:-${container:-}}"
    printf "Default container name or ID [%s]: " "${current_default:-<none>}"
    local container_input
    read -r container_input
    container_input=${container_input:-$current_default}
    if [[ -n "$container_input" && "$container_input" != "<none>" ]]; then
        default_container="$container_input"
    fi
}

prompt_project_scope() {
    local force_reprompt="${1:-false}"
    local project_default="${project_name:-Personal}"
    if [[ "$project_name_source" != "default" && "$force_reprompt" != "true" ]]; then
        return
    fi

    printf "Project to manage [%s]: " "$project_default"
    local project_input
    read -r project_input
    if [[ -n "$project_input" ]]; then
        set_project_from_path "$project_input"
        project_name_source="interactive"
    fi

    local current_hint="${n8n_path:-}"
    if [[ -z "$current_hint" ]]; then
        printf "Optional n8n folder path within project (leave blank for project root): "
    else
        printf "Optional n8n folder path within project [%s]: " "$current_hint"
    fi
    local path_input
    read -r path_input
    if [[ -n "$path_input" ]]; then
        set_n8n_path_hint "$path_input" "interactive"
    elif [[ "$force_reprompt" == "true" ]]; then
        set_n8n_path_hint "$current_hint" "interactive"
    fi
}

prompt_dated_backup_choice() {
    local force_reprompt="${1:-false}"
    if [[ "$action" != "backup" ]]; then
        return
    fi
    if [[ "$dated_backups_source" != "default" && "$force_reprompt" != "true" ]]; then
        return
    fi
    local default_label="no"
    if [[ "$dated_backups" == "true" ]]; then
        default_label="yes"
    fi
    printf "Create dated backups (timestamped directories)? (yes/no) [%s]: " "$default_label"
    local choice
    read -r choice
    choice=${choice:-$default_label}
    if [[ "$choice" =~ ^([Yy]es|[Yy])$ ]]; then
        dated_backups=true
    else
        dated_backups=false
    fi
    dated_backups_source="interactive"
}

prompt_local_backup_settings() {
    local force_reprompt="${1:-false}"
    local has_local_storage=false
    if [[ "$workflows" == "1" ]] || [[ "$credentials" == "1" ]] || [[ "$environment" == "1" ]]; then
        has_local_storage=true
    fi

    if [[ "$has_local_storage" == true ]] && ([[ "$local_backup_path_source" == "default" ]] || [[ "$force_reprompt" == "true" ]]); then
        printf "Local backup directory [%s]: " "$local_backup_path"
        local backup_input
        read -r backup_input
        if [[ -n "$backup_input" ]]; then
            if [[ "$backup_input" =~ ^~ ]]; then
                backup_input="${backup_input/#\~/$HOME}"
            fi
            local_backup_path="$backup_input"
            local_backup_path_source="interactive"
        fi
    fi

    if [[ "$has_local_storage" == true ]] && ([[ "$local_rotation_limit_source" == "default" ]] || [[ "$force_reprompt" == "true" ]]); then
        while true; do
            printf "Local backup rotation limit [%s]: " "$local_rotation_limit"
            local rotation_input
            read -r rotation_input
            rotation_input=${rotation_input:-$local_rotation_limit}
            if [[ "$rotation_input" =~ ^(0|[0-9]+|unlimited)$ ]]; then
                local_rotation_limit="$rotation_input"
                local_rotation_limit_source="interactive"
                break
            fi
            log ERROR "Invalid rotation value. Use 0, a positive number, or 'unlimited'."
        done
    fi
}

prompt_credentials_encryption() {
    local force_reprompt="${1:-false}"
    if [[ "$credentials" == "0" ]]; then
        return
    fi
    if [[ "$assume_defaults" == "true" && "$force_reprompt" != "true" ]]; then
        return
    fi
    if [[ "$credentials_encrypted_source" != "default" && "$force_reprompt" != "true" ]]; then
        return
    fi

    local default_label="yes"
    if [[ "$credentials_encrypted" == "false" ]]; then
        default_label="no"
    fi
    printf "Export credentials encrypted by n8n (recommended)? (yes/no) [%s]: " "$default_label"
    local choice
    read -r choice
    choice=${choice:-$default_label}
    if [[ "$choice" =~ ^([Yy]es|[Yy])$ ]]; then
        credentials_encrypted=true
        credentials_encrypted_source="interactive"
        return
    fi

    log WARN "⚠️  Credentials will be exported decrypted. Protect the files carefully."
    if [[ "$credentials" == "2" ]]; then
        printf "Decrypted credentials would be stored in Git history. Continue? (yes/no) [no]: "
        local confirm
        read -r confirm
        confirm=${confirm:-no}
        if [[ "$confirm" =~ ^([Yy]es|[Yy])$ ]]; then
            credentials_encrypted=false
            credentials_encrypted_source="interactive"
        else
            credentials_encrypted=true
            credentials_encrypted_source="interactive"
        fi
    else
        credentials_encrypted=false
        credentials_encrypted_source="interactive"
    fi
}

prompt_folder_structure_settings() {
    local force_reprompt="${1:-false}"
    local skip_validation="${2:-false}"

    if [[ "$workflows" != "2" ]]; then
        folder_structure=false
        return
    fi

    if [[ "$folder_structure_source" != "default" && "$force_reprompt" != "true" ]]; then
        return
    fi

    printf "Mirror n8n folder structure in Git? (yes/no) [no]: "
    local choice
    read -r choice
    choice=${choice:-no}
    if [[ "$choice" =~ ^([Yy]es|[Yy])$ ]]; then
        folder_structure=true
    else
        folder_structure=false
    fi
    folder_structure_source="interactive"

    if [[ "$folder_structure" != "true" ]]; then
        return
    fi

    while [[ -z "$n8n_base_url" ]]; do
        printf "n8n base URL (e.g., http://localhost:5678): "
        read -r n8n_base_url
        if [[ -z "$n8n_base_url" ]]; then
            log ERROR "n8n base URL is required when folder structure is enabled."
        fi
    done

    printf "n8n API key (leave blank to use stored credential): "
    read -r -s n8n_api_key
    echo
    if [[ -z "$n8n_api_key" ]]; then
        local default_cred_name="${n8n_session_credential:-N8N REST BACKUP}"
        printf "n8n credential name for session auth [%s]: " "$default_cred_name"
        read -r n8n_session_credential
        n8n_session_credential=${n8n_session_credential:-$default_cred_name}
    else
        n8n_session_credential=""
    fi

    if [[ "$skip_validation" != "true" ]]; then
        log INFO "Validating n8n API access..."
        if ! validate_n8n_api_access "$n8n_base_url" "$n8n_api_key" "$n8n_email" "$n8n_password" "$container" "$n8n_session_credential"; then
            log ERROR "❌ n8n API validation failed!"
            log ERROR "Authentication failed with all available methods."
            log ERROR "Cannot proceed with folder structure creation."
            log INFO "💡 Please verify:"
            log INFO "   1. n8n instance is running and accessible"
            log INFO "   2. Credentials (API key or stored credential) are correct"
            log INFO "   3. No authentication barriers blocking access"
            exit 1
        else
            log SUCCESS "✅ n8n API configuration validated successfully!"
            log INFO "✅ Folder structure enabled with n8n API integration"
        fi
    else
        log INFO "Skipping n8n API validation (configuration wizard)."
    fi
}

prompt_storage_modes() {
    local force_reprompt="${1:-false}"
    if [[ "$force_reprompt" == "true" || "$workflows_source" == "default" ]]; then
        select_workflows_storage
        workflows_source="interactive"
    fi
    if [[ "$force_reprompt" == "true" || "$credentials_source" == "default" ]]; then
        select_credentials_storage
        credentials_source="interactive"
    fi
    if [[ "$force_reprompt" == "true" || "$environment_source" == "default" ]]; then
        select_environment_storage
        environment_source="interactive"
    fi
}

prompt_dry_run_choice() {
    local force_reprompt="${1:-false}"
    if [[ "$dry_run_source" != "default" && "$force_reprompt" != "true" ]]; then
        return
    fi
    local default_label="no"
    if [[ "$dry_run" == "true" ]]; then
        default_label="yes"
    fi
    printf "Run in dry-run mode by default? (yes/no) [%s]: " "$default_label"
    local choice
    read -r choice
    choice=${choice:-$default_label}
    if [[ "$choice" =~ ^([Yy]es|[Yy])$ ]]; then
        dry_run=true
    else
        dry_run=false
    fi
    dry_run_source="interactive"
}

collect_backup_preferences() {
    local force_reprompt="${1:-false}"
    local skip_validation="${2:-false}"

    prompt_project_scope "$force_reprompt"
    prompt_dated_backup_choice "$force_reprompt"
    prompt_storage_modes "$force_reprompt"
    prompt_local_backup_settings "$force_reprompt"
    prompt_folder_structure_settings "$force_reprompt" "$skip_validation"
    prompt_credentials_encryption "$force_reprompt"
}

expand_config_path() {
    local raw="$1"
    if [[ -z "$raw" ]]; then
        printf '%s\n' ""
        return
    fi
    if [[ "$raw" == ~* ]]; then
        printf '%s\n' "${raw/#\~/$HOME}"
    else
        printf '%s\n' "$raw"
    fi
}

escape_config_value() {
    local value="$1"
    printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_config_file() {
    local destination_path
    destination_path="$(expand_config_path "$1")"

    if [[ -z "$destination_path" ]]; then
        log ERROR "No configuration destination provided."
        return 1
    fi

    local target_dir
    target_dir="$(dirname "$destination_path")"

    if ! mkdir -p "$target_dir"; then
        log ERROR "Failed to create config directory: $target_dir"
        return 1
    fi

    local -a lines
    lines+=("# Generated by n8n-manager configuration wizard on $(date -u +%Y-%m-%dT%H:%M:%SZ)")
    lines+=("# Location: $destination_path")
    lines+=("")

    if [[ -n "$github_token" ]]; then
        lines+=("GITHUB_TOKEN=\"$(escape_config_value "$github_token")\"")
    fi
    if [[ -n "$github_repo" ]]; then
        lines+=("GITHUB_REPO=\"$(escape_config_value "$github_repo")\"")
    fi
    if [[ -n "$github_branch" ]]; then
        lines+=("GITHUB_BRANCH=\"$(escape_config_value "$github_branch")\"")
    fi
    if [[ -n "$github_path" ]]; then
        lines+=("GITHUB_PATH=\"$(escape_config_value "$github_path")\"")
    fi

    if [[ -n "$default_container" ]]; then
        lines+=("DEFAULT_CONTAINER=\"$(escape_config_value "$default_container")\"")
    fi

    if [[ -n "$project_name" ]]; then
        lines+=("N8N_PROJECT=\"$(escape_config_value "$project_name")\"")
    fi
    if [[ -n "$n8n_path" ]]; then
        lines+=("N8N_PATH=\"$(escape_config_value "$n8n_path")\"")
    fi

    if [[ -n "$workflows" ]]; then
        lines+=("WORKFLOWS=\"$workflows\"")
    fi
    if [[ -n "$credentials" ]]; then
        lines+=("CREDENTIALS=\"$credentials\"")
    fi
    if [[ -n "$environment" ]]; then
        lines+=("ENVIRONMENT=\"$environment\"")
    fi

    if [[ -n "$local_backup_path" ]]; then
        lines+=("LOCAL_BACKUP_PATH=\"$(escape_config_value "$local_backup_path")\"")
    fi
    if [[ -n "$local_rotation_limit" ]]; then
        lines+=("LOCAL_ROTATION_LIMIT=\"$(escape_config_value "$local_rotation_limit")\"")
    fi

    if [[ -n "$dated_backups" ]]; then
        lines+=("DATED_BACKUPS=\"$dated_backups\"")
    fi

    if [[ "$credentials_encrypted" == "false" ]]; then
        lines+=("DECRYPT_CREDENTIALS=\"true\"")
    else
        lines+=("DECRYPT_CREDENTIALS=\"false\"")
    fi

    if [[ -n "$folder_structure" ]]; then
        lines+=("FOLDER_STRUCTURE=\"$folder_structure\"")
    fi
    if [[ "$folder_structure" == "true" ]]; then
        lines+=("N8N_BASE_URL=\"$(escape_config_value "$n8n_base_url")\"")
        if [[ -n "$n8n_api_key" ]]; then
            lines+=("N8N_API_KEY=\"$(escape_config_value "$n8n_api_key")\"")
        fi
        if [[ -n "$n8n_session_credential" ]]; then
            lines+=("N8N_LOGIN_CREDENTIAL_NAME=\"$(escape_config_value "$n8n_session_credential")\"")
        fi
    fi

    if [[ -n "$dry_run" ]]; then
        lines+=("DRY_RUN=\"$dry_run\"")
    fi
    if [[ -n "$verbose" ]]; then
        lines+=("VERBOSE=\"$verbose\"")
    fi

    {
        for line in "${lines[@]}"; do
            printf '%s\n' "$line"
        done
    } > "$destination_path"

    if ! chmod 600 "$destination_path" 2>/dev/null; then
        log WARN "Could not set permissions on $destination_path. Please ensure it is protected manually."
    fi

    log SUCCESS "Configuration saved to $destination_path"
    return 0
}

select_config_destination() {
    local has_cli=false
    local cli_path=""
    if [[ -n "$config_file" ]]; then
        cli_path="$(expand_config_path "$config_file")"
        has_cli=true
    fi

    local default_option="2"
    if [[ "$has_cli" == true ]]; then
        default_option="3"
    fi

    while true; do
        log HEADER "Choose configuration destination"
        log INFO "1) Project config: $LOCAL_CONFIG_FILE"
        log INFO "2) User config: $USER_CONFIG_FILE"
        if [[ "$has_cli" == true ]]; then
            log INFO "3) --config path: $cli_path"
            log INFO "4) Enter a different custom path"
        else
            log INFO "3) Enter a custom path"
        fi

        printf "Select option [%s]: " "$default_option"
        local selection
        read -r selection
        selection=${selection:-$default_option}

        case "$selection" in
            1)
                CONFIG_WIZARD_TARGET="$LOCAL_CONFIG_FILE"
                break
                ;;
            2)
                CONFIG_WIZARD_TARGET="$USER_CONFIG_FILE"
                break
                ;;
            3)
                if [[ "$has_cli" == true ]]; then
                    if [[ -z "$cli_path" ]]; then
                        log ERROR "The --config path is empty; please choose another option."
                    else
                        CONFIG_WIZARD_TARGET="$cli_path"
                        break
                    fi
                else
                    printf "Enter full path to configuration file: "
                    local custom_path
                    read -r custom_path
                    custom_path="$(expand_config_path "$custom_path")"
                    if [[ -z "$custom_path" ]]; then
                        log ERROR "Custom path cannot be empty."
                    else
                        CONFIG_WIZARD_TARGET="$custom_path"
                        break
                    fi
                fi
                ;;
            4)
                if [[ "$has_cli" == true ]]; then
                    printf "Enter full path to configuration file: "
                    local custom_path
                    read -r custom_path
                    custom_path="$(expand_config_path "$custom_path")"
                    if [[ -z "$custom_path" ]]; then
                        log ERROR "Custom path cannot be empty."
                    else
                        CONFIG_WIZARD_TARGET="$custom_path"
                        break
                    fi
                else
                    log ERROR "Invalid selection."
                fi
                ;;
            *)
                log ERROR "Invalid selection."
                ;;
        esac
    done

    log INFO "Configuration will be saved to: $CONFIG_WIZARD_TARGET"
}

run_configuration_wizard() {
    log HEADER "n8n-manager configuration wizard"
    select_config_destination
    log INFO "This will create or update your configuration at $CONFIG_WIZARD_TARGET"

    prompt_default_container

    local wizard_force="true"
    action="backup"
    project_name_source="default"
    workflows_source="default"
    credentials_source="default"
    environment_source="default"
    dated_backups_source="default"
    local_backup_path_source="${local_backup_path_source:-default}"
    local_rotation_limit_source="${local_rotation_limit_source:-default}"
    folder_structure_source="default"
    credentials_encrypted_source="default"
    dry_run_source="default"

    collect_backup_preferences "$wizard_force" "true"
    prompt_dry_run_choice "$wizard_force"

    local needs_github=false
    if [[ "$workflows" == "2" ]] || [[ "$credentials" == "2" ]] || [[ "$environment" == "2" ]]; then
        needs_github=true
    fi

    if [[ "$needs_github" == true ]]; then
        get_github_config "true"
        local previous_action="$action"
        action="backup"
        prompt_github_path_prefix
        action="$previous_action"
    else
        log INFO "GitHub settings omitted (local-only storage)."
        github_token=""
        github_repo=""
        github_branch=""
        github_path=""
    fi

    write_config_file "$CONFIG_WIZARD_TARGET"
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

select_environment_storage() {
    log HEADER "Choose Environment Backup Mode"
    echo "0) Disabled - Skip environment variable backup"
    echo "1) Local Storage - Store environment variables in local secure storage"
    echo "2) Remote Storage - Store environment variables in Git repository (NOT RECOMMENDED)"

    local choice
    while true; do
        printf "Select environment backup mode (0-2) [default: 0]: "
        read -r choice
        choice=${choice:-0}
        case "$choice" in
            0) environment=0; log INFO "Environment backup: (0) disabled"; return ;;
            1) environment=1; log INFO "Environment backup: (1) local"; return ;;
            2)
                log WARN "You selected REMOTE STORAGE for environment variables!"
                printf "Are you sure you want to commit environment variables to Git? (y/N): "
                read -r confirm_env
                if [[ "$confirm_env" =~ ^[Yy]$ ]]; then
                    environment=2
                    log WARN "Environment backup: (2) remote (high risk)"
                    return
                else
                    log INFO "Environment backup remains disabled."
                    environment=0
                    return
                fi
                ;;
            *) echo "Invalid choice. Please enter 0, 1, or 2." ;;
        esac
    done
}

prompt_github_path_prefix() {
    log HEADER "GitHub Storage Path"
    local action_context="${action:-backup}"
    local context_label="GitHub backup"
    if [[ "$action_context" == "restore" ]]; then
        context_label="GitHub restore"
    fi

    local effective_prefix
    effective_prefix="$(effective_repo_prefix)"

    if [[ -n "$effective_prefix" ]]; then
        log INFO "Current $context_label path: $effective_prefix"
    else
        log INFO "Current $context_label path: <repository root>"
    fi

    while true; do
        local hint_prefix=""
        if [[ "$github_path_source" == "default" || "$github_path_source" == "unset" ]]; then
            if [[ -n "$n8n_path" ]]; then
                hint_prefix="$n8n_path"
            elif [[ "${n8n_path_source:-default}" != "default" && "${n8n_path_source:-unset}" != "unset" ]]; then
                hint_prefix="/"
            else
                hint_prefix="$project_slug"
            fi
        else
            hint_prefix="$effective_prefix"
        fi

        if [[ "$hint_prefix" == "/" || -z "$hint_prefix" ]]; then
            printf "GitHub path prefix (press Enter to keep repository root, '/' for repository root): "
        else
            printf "GitHub path prefix (press Enter for %s, '/' for repository root): " "$hint_prefix"
        fi

        local path_input
        read -r path_input

        if [[ -z "$path_input" ]]; then
            if [[ "$github_path_source" == "unset" ]]; then
                github_path_source="default"
            fi
            local final_prefix
            final_prefix="$(effective_repo_prefix)"
            if [[ -n "$final_prefix" ]]; then
                if [[ "$action_context" == "restore" ]]; then
                    log INFO "GitHub restore will read from: $final_prefix"
                else
                    log INFO "GitHub backups will be stored under: $final_prefix"
                fi
            else
                if [[ "$action_context" == "restore" ]]; then
                    log INFO "GitHub restore will use the repository root."
                else
                    log INFO "GitHub backups will be stored at the repository root."
                fi
            fi
            return
        fi

        if [[ "$path_input" == "/" ]]; then
            github_path=""
            github_path_source="interactive"
            if [[ "$action_context" == "restore" ]]; then
                log INFO "GitHub restore will use the repository root."
            else
                log INFO "GitHub backups will be stored at the repository root."
            fi
            return
        fi

        local normalized
        normalized="$(normalize_github_path_prefix "$path_input")"
        if [[ -z "$normalized" ]]; then
            log WARN "Path removed all characters after normalization. Enter '/' for repository root or press Enter for the default project path."
            continue
        fi

        github_path="$normalized"
        github_path_source="interactive"
        if [[ "$action_context" == "restore" ]]; then
            log INFO "GitHub restore will read from: $github_path"
        else
            log INFO "GitHub backups will be stored under: $github_path"
        fi
        return
    done
}