#!/usr/bin/env bash
# =========================================================
# n8n-manager.sh - Interactive backup/restore for n8n
# =========================================================
# Flexible Backup System:
# - Workflows: local files or Git repository (user choice)
# - Credentials: local files or Git repository (user choice)
# - Local storage with proper permissions (chmod 600)
# - Archive rotation for local backups (5-10 backups)
# - .gitignore management for Git repositories
# - Version control: [New]/[Updated]/[Deleted] commit messages
# - Folder mirroring: Git structure matches n8n interface
# =========================================================

set -Eeuo pipefail
IFS=$'\n\t'

# Get script directory for relative imports
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Configuration ---
# Configuration file paths (local first, then user directory)
LOCAL_CONFIG_FILE="$SCRIPT_DIR/.config"
USER_CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/n8n-manager/config"

# --- Global Configuration Variables ---
VERSION="4.1.0"
DEBUG_TRACE=${DEBUG_TRACE:-false}

# Selected values from interactive mode
SELECTED_ACTION=""
SELECTED_CONTAINER_ID=""
SELECTED_RESTORE_TYPE="all"

# ==============================================================================
# RUNTIME CONFIGURATION - Single source of truth for all settings  
# ==============================================================================
# These variables represent the final runtime state and are used throughout
# the application. They are populated through a hierarchy:
# 1. Defaults (set here)
# 2. Config file values (load_config)  
# 3. Command line arguments (parse_args)
# 4. Interactive prompts (interactive_mode)

# Core operation settings
action=""
container=""
default_container=""           # Default container from config
credentials_encrypted=""      # empty = unset, true=encrypted (default), false=decrypted (loaded from DECRYPT_CREDENTIALS config, inverted)
assume_defaults=""            # empty = unset, true/false = explicitly configured
# Control flags
dry_run=""     # empty = unset, true/false = explicitly configured
verbose=""     # empty = unset, true/false = explicitly configured
needs_github="" # tracks if GitHub access is required

github_path=""
github_path_source="unset"

# Git/GitHub settings  
github_token=""
github_repo=""
github_branch="main"
dated_backups=""  # empty = unset, true/false = explicitly configured

# Storage settings (handled by numeric config)
workflows=""              # empty = unset, 0=disabled, 1=local, 2=remote
credentials=""            # empty = unset, 0=disabled, 1=local, 2=remote
environment=""            # empty = unset, 0=disabled, 1=local, 2=remote
local_backup_path="$HOME/n8n-backup"
local_rotation_limit="10"

# Track configuration value sources (cli/config/default/interactive)
workflows_source="unset"
credentials_source="unset"
environment_source="unset"
local_backup_path_source="unset"
local_rotation_limit_source="unset"
dated_backups_source="unset"
dry_run_source="unset"
folder_structure_source="unset"
credentials_encrypted_source="unset"
assume_defaults_source="unset"

# Advanced features
folder_structure=""            # empty = unset, true/false = explicitly configured
n8n_base_url=""               # Required if folder_structure=true
n8n_api_key=""                # Optional - session auth used if empty
n8n_session_credential=""     # Optional - credential name stored inside n8n
n8n_email=""                  # Optional - for session auth
n8n_password=""               # Optional - for session auth

# Logging and misc
log_file=""                # Custom log file path
restore_type="all"            # all|workflows|credentials
restore_workflows_mode=""     # 0=skip, 1=local, 2=remote Git
restore_credentials_mode=""   # 0=skip, 1=local, 2=remote Git
restore_folder_structure_preference="" # true/false preference for applying folder manifest
restore_folder_structure_preference_source="unset"
credentials_folder_name="${credentials_folder_name:-.credentials}" # default credentials folder for remote storage
config_file=""                # Custom config file path

# Load all modules
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/interactive.sh" 
source "$SCRIPT_DIR/lib/n8n-api.sh"
source "$SCRIPT_DIR/lib/git.sh"
source "$SCRIPT_DIR/lib/backup.sh"
source "$SCRIPT_DIR/lib/restore.sh"

# --- Main Function ---
main() {
    # Parse command-line arguments first
    while [ $# -gt 0 ]; do
        case $1 in
            --action) action="$2"; shift 2 ;; 
            --container) container="$2"; shift 2 ;; 
            --token) github_token="$2"; shift 2 ;; 
            --repo) github_repo="$2"; shift 2 ;; 
            --branch) github_branch="$2"; shift 2 ;; 
            --config) config_file="$2"; shift 2 ;; 
            --dated) dated_backups=true; dated_backups_source="cli"; shift 1 ;;
                        --workflows)
                case "${2,,}" in  # Convert to lowercase
                    0|disabled) workflows=0; workflows_source="cli"; shift 2 ;;
                    1|local) workflows=1; workflows_source="cli"; shift 2 ;;
                    2|remote) workflows=2; workflows_source="cli"; shift 2 ;;
                    *) log ERROR "Invalid workflows value: $2. Must be 0/disabled, 1/local, or 2/remote"
                       exit 1 ;;
                esac
                ;;
            --credentials)
                case "${2,,}" in  # Convert to lowercase
                    0|disabled) credentials=0; credentials_source="cli"; shift 2 ;;
                    1|local) credentials=1; credentials_source="cli"; shift 2 ;;
                    2|remote) credentials=2; credentials_source="cli"; shift 2 ;;
                    *) log ERROR "Invalid credentials value: $2. Must be 0/disabled, 1/local, or 2/remote"
                       exit 1 ;;
                esac
                ;;
            --environment)
                case "${2,,}" in
                    0|disabled) environment=0; environment_source="cli"; shift 2 ;;
                    1|local) environment=1; environment_source="cli"; shift 2 ;;
                    2|remote) environment=2; environment_source="cli"; shift 2 ;;
                    *) log ERROR "Invalid environment value: $2. Must be 0/disabled, 1/local, or 2/remote"
                       exit 1 ;;
                esac
                ;;
            --path) local_backup_path="$2"; local_backup_path_source="cli"; shift 2 ;;
            --github-path)
                local raw_github_path="$2"
                github_path="$(normalize_github_path_prefix "$raw_github_path")"
                if [[ -z "$github_path" && -n "$raw_github_path" ]]; then
                    log WARN "--github-path value '$raw_github_path' normalized to empty; clearing prefix."
                fi
                github_path_source="cli"
                shift 2 ;;
            --decrypt)
                # Enable/disable encrypted credentials export on CLI
                case "${2,,}" in
                    true|1|yes|on) credentials_encrypted=true; credentials_encrypted_source="cli"; shift 2 ;;
                    false|0|no|off) credentials_encrypted=false; credentials_encrypted_source="cli"; shift 2 ;;
                    *) log ERROR "Invalid value for --decrypt: $2. Use true/false"; exit 1 ;;
                esac
                ;;
            --rotation)
                if [[ -n "$2" && "$2" != -* ]]; then
                    local_rotation_limit="$2"; local_rotation_limit_source="cli"; shift 2
                else
                    echo -e "${YELLOW}[INFO]${NC}   Valid rotation options:" >&2
                    echo -e "${YELLOW}[INFO]${NC}   • 0          - No rotation (overwrite current backup)" >&2
                    echo -e "${YELLOW}[INFO]${NC}   • <number>   - Keep N most recent backups (creates archive/timestamp dirs)" >&2
                    echo -e "${YELLOW}[INFO]${NC}   • unlimited  - Keep all backups (no deletion)" >&2
                    echo -e "${RED}[ERROR]${NC} Missing required argument for --rotation" >&2
                    exit 1
                fi
                ;;
            --dry-run) dry_run=true; dry_run_source="cli"; shift 1 ;;
            --verbose) verbose=true; shift 1 ;; 
            --log-file) log_file="$2"; shift 2 ;; 
            --folder-structure) folder_structure=true; folder_structure_source="cli"; shift 1 ;;
            --defaults) assume_defaults=true; assume_defaults_source="cli"; shift 1 ;;
            --n8n-url) n8n_base_url="$2"; shift 2 ;;
            --n8n-api-key) n8n_api_key="$2"; shift 2 ;;
            --n8n-cred) n8n_session_credential="$2"; shift 2 ;;
            -h|--help) show_help; exit 0 ;;
            *) echo "[ERROR] Invalid option: $1"; show_help; exit 1 ;;
        esac
    done

    # Load config file (must happen after parsing args)
    load_config

    if [[ -z "$environment" ]]; then
        environment=0
        environment_source="default"
    fi

    if [[ -z "$github_path" ]]; then
        github_path=""
    fi
    if [[ "$github_path_source" == "unset" ]]; then
        github_path_source="default"
    fi

    log HEADER "n8n Backup/Restore Manager v$VERSION"
    log INFO "🚀 Flexible backup storage: local files or Git repository"
    
    check_host_dependencies

    if [[ -z "$assume_defaults" ]]; then
        assume_defaults=false
        assume_defaults_source="${assume_defaults_source:-default}"
    fi

    local stdin_is_tty=false
    if [ -t 0 ]; then
        stdin_is_tty=true
    fi

    local interactive_mode=false
    if [[ "$stdin_is_tty" == "true" && "$assume_defaults" != "true" ]]; then
        interactive_mode=true
    fi

    if [[ "$assume_defaults" == "true" && -z "$credentials_encrypted" ]]; then
        credentials_encrypted=true
        credentials_encrypted_source="${credentials_encrypted_source:-defaults}"
    fi

    # Runtime variables are now lowercase and used directly
    log DEBUG "Action: $action, Container: $container, Repo: $github_repo"
    log DEBUG "Branch: $github_branch, Workflows: ($workflows) $(format_storage_value $workflows), Credentials: ($credentials) $(format_storage_value $credentials)"
    log DEBUG "Local Path: $local_backup_path, Rotation: $local_rotation_limit"
    if [[ -n "$github_path" ]]; then
        log DEBUG "GitHub path prefix: $github_path (source: $github_path_source)"
    else
        log DEBUG "GitHub path prefix: <none> (source: $github_path_source)"
    fi
    
    if [[ "$action" == "restore" ]]; then
        if [[ -z "$restore_workflows_mode" && -n "$workflows" ]]; then
            restore_workflows_mode="$workflows"
        fi
        if [[ -z "$restore_credentials_mode" && -n "$credentials" ]]; then
            restore_credentials_mode="$credentials"
        fi
        case "$restore_type" in
            workflows)
                restore_workflows_mode=${restore_workflows_mode:-2}
                restore_credentials_mode=${restore_credentials_mode:-0}
                ;;
            credentials)
                restore_workflows_mode=${restore_workflows_mode:-0}
                restore_credentials_mode=${restore_credentials_mode:-1}
                ;;
            all|*)
                restore_workflows_mode=${restore_workflows_mode:-2}
                restore_credentials_mode=${restore_credentials_mode:-1}
                ;;
        esac

        if [[ -z "$restore_folder_structure_preference" ]]; then
            if [[ "$folder_structure" == "true" ]]; then
                restore_folder_structure_preference="true"
                restore_folder_structure_preference_source="${folder_structure_source:-config}"
            else
                restore_folder_structure_preference="false"
                restore_folder_structure_preference_source="${folder_structure_source:-default}"
            fi
        fi
    fi

    # Calculate if GitHub access is needed
    needs_github=false
    if [[ "$action" == "restore" ]]; then
        if [[ "${restore_workflows_mode:-0}" == "2" ]] || [[ "${restore_credentials_mode:-0}" == "2" ]]; then
            needs_github=true
        fi
    else
        if [[ "$workflows" == "2" ]] || [[ "$credentials" == "2" ]] || [[ "$environment" == "2" ]]; then
            needs_github=true
        fi
    fi

    # Set intelligent defaults for backup (only if not already configured)
    if [[ "$action" == "backup" ]]; then
        # Check if both are disabled after config loading
        if [[ "$workflows" == "0" && "$credentials" == "0" && "$environment" == "0" ]]; then
            log ERROR "Both workflows and credentials are disabled. Nothing to backup!"
            log INFO "Please specify backup options:"
            log INFO "  --workflows 1 --credentials 1     (both stored locally - secure)"
            log INFO "  --workflows 2 --credentials 1     (workflows to Git, credentials local)"
            log INFO "  --workflows 1 --credentials 2     (workflows local, credentials to Git)"
            log INFO "  --workflows 2 --credentials 2     (both to Git - less secure)"
            log INFO "  --workflows 1                     (workflows local only, skip credentials)"
            log INFO "  --credentials 1                   (credentials local only, skip workflows)"
            log INFO "  --environment 1                   (capture environment variables locally)"
            log INFO "  --environment 2                   (push environment variables to Git - high risk)"
            exit 1
        fi
        
        # Only apply defaults if no config was provided and no command line args
        # (This should rarely happen since config loading sets defaults)
        if [[ -z "${WORKFLOWS:-}" && -z "${workflows:-}" && -z "${CREDENTIALS:-}" && -z "${credentials:-}" ]]; then
            log DEBUG "No storage configuration found anywhere - applying fallback defaults"
            workflows=1  # Default to local
            credentials=1  # Default to local
            log INFO "No storage options specified - defaulting to local storage for both workflows and credentials"
        fi
    fi

    # Debug logging
    log DEBUG "Action: $action, Container: $container, Repo: $github_repo"
    log DEBUG "Branch: $github_branch, Workflows: ($workflows) $(format_storage_value $workflows), Credentials: ($credentials) $(format_storage_value $credentials), Environment: ($environment) $(format_storage_value $environment)"
    log DEBUG "Local Path: $local_backup_path, Rotation: $local_rotation_limit"

    # Check if running non-interactively
    if [[ "$interactive_mode" != "true" ]]; then
        log DEBUG "Running in non-interactive mode."
        
        # Set defaults for boolean variables if still empty (not configured)
        dated_backups=${dated_backups:-false}
        folder_structure=${folder_structure:-false}
        verbose=${verbose:-false}
        dry_run=${dry_run:-false}
        
        # Basic parameters are always required
        if [ -z "$action" ] || [ -z "$container" ]; then
            log ERROR "Running in non-interactive mode but required parameters are missing."
            log INFO "Please provide --action and --container via arguments or config file."
            show_help
            exit 1
        fi
        
        # GitHub parameters only required for remote operations or restore
        if [[ $needs_github == true ]]; then
            if [ -z "$github_token" ] || [ -z "$github_repo" ]; then
                log ERROR "GitHub token and repository are required for remote operations or restore."
                log INFO "Please provide --token and --repo via arguments or config file."
                show_help
                exit 1
            fi
        fi
        
        # n8n base URL required when folder structure is enabled
        if [[ "$folder_structure" == "true" ]]; then
            if [[ -z "$n8n_base_url" ]]; then
                log ERROR "n8n base URL is required when folder structure is enabled."
                log INFO "Please provide --n8n-url via arguments or config file."
                log INFO "API key (--n8n-api-key) is optional - if not provided, will use session authentication."
                show_help
                exit 1
            fi
            
            if [[ -z "$n8n_api_key" ]]; then
                if [[ -z "$n8n_email" || -z "$n8n_password" ]]; then
                    if [[ -z "$n8n_session_credential" ]]; then
                        log ERROR "Session credential name required when API key is not provided."
                        log INFO "Please configure --n8n-cred or set N8N_LOGIN_CREDENTIAL_NAME in config."
                        exit 1
                    fi
                fi
            fi

            # Validate API access
            log INFO "Validating n8n API access..."
            if ! validate_n8n_api_access "$n8n_base_url" "$n8n_api_key" "$n8n_email" "$n8n_password" "$container" "$n8n_session_credential"; then
                log ERROR "❌ n8n API validation failed!"
                log ERROR "Please check your URL and credentials."
                log INFO "💡 Tip: You can test manually with:"
                if [[ -n "$n8n_api_key" ]]; then
                    log INFO "   curl -H \"X-N8N-API-KEY: your_key\" \"$n8n_base_url/api/v1/workflows?limit=1\""
                else
                    log INFO "   Session authentication will be used with email/password login"
                fi
                exit 1
            fi
            log SUCCESS "✅ n8n API configuration validated successfully!"
        fi

        # Validate container
        log DEBUG "Validating non-interactive container: $container"
        # Sanitize container variable to remove any potential newlines or special chars
        container=$(echo "$container" | tr -d '\n\r' | xargs)
        local found_id
        # Try to find container by ID first, then by name
        found_id=$(docker ps -q --filter "id=$container" | head -n 1)
        if [ -z "$found_id" ]; then
            found_id=$(docker ps -q --filter "name=$container" | head -n 1)
        fi
        if [ -z "$found_id" ]; then
             log ERROR "Specified container '${container}' not found or not running."
             log INFO "Please check that the container exists and is currently running."
             log INFO "Use 'docker ps' to see available running containers."
             exit 1
        fi
        container=$found_id
        log SUCCESS "Using specified container: $container"

    else
        log DEBUG "Running in interactive mode."
        
        # Interactive action selection
        if [ -z "$action" ]; then 
            select_action
            action="$SELECTED_ACTION"
        fi
        log DEBUG "Action selected: $action"
        
        # Handle reconfigure action
        if [[ "$action" == "reconfigure" ]]; then
            log INFO "🔄 Reconfiguring - will re-prompt for all settings..."
            
            # Set reconfigure flag to force all interactive prompts to re-ask
            reconfigure_mode=true
            
            # Select new action after setting reconfigure mode
            select_action
            action="$SELECTED_ACTION"
            log INFO "✅ Reconfigure mode enabled. All prompts will re-ask for values during $action..."
        else
            reconfigure_mode=false
        fi
        
        # Interactive container selection
        if [[ -z "$container" ]] || [[ "$reconfigure_mode" == "true" ]]; then
            select_container
            container="$SELECTED_CONTAINER_ID"
        else
            log DEBUG "Validating specified container: $container"
            # Sanitize container variable to remove any potential newlines or special chars
            container=$(echo "$container" | tr -d '\n\r' | xargs)
            local found_id
            # Try to find container by ID first, then by name
            found_id=$(docker ps -q --filter "id=$container" | head -n 1)
            if [ -z "$found_id" ]; then
                found_id=$(docker ps -q --filter "name=$container" | head -n 1)
            fi
            if [ -z "$found_id" ]; then
                 log ERROR "Specified container '${container}' not found or not running."
                 log INFO "The container may have been stopped or the name/ID may be incorrect."
                 log WARN "Falling back to interactive container selection..."
                 echo
                 select_container
                 container="$SELECTED_CONTAINER_ID"
            else
                 container=$found_id
                 log SUCCESS "Using specified container: $container"
            fi
        fi
        log DEBUG "Container selected: $container"
        
        # Interactive dated backup prompt (only if value originated from defaults or reconfigure mode)
        if [[ "$action" == "backup" ]] && ([[ "$dated_backups_source" == "default" ]] || [[ "$reconfigure_mode" == "true" ]]); then
             printf "Create a dated backup (in a timestamped subdirectory)? (yes/no) [no]: "
             local confirm_dated
             read -r confirm_dated
             if [[ "$confirm_dated" == "yes" || "$confirm_dated" == "y" ]]; then
                 dated_backups=true
             else
                 dated_backups=false
             fi
             dated_backups_source="interactive"
        fi
        log DEBUG "Use Dated Backup: $dated_backups"
        
        # Interactive storage configuration using new selection functions
        if [[ "$action" == "backup" ]]; then
            local prompt_workflows=false
            local prompt_credentials=false
            local prompt_environment=false

            if [[ "$reconfigure_mode" == "true" ]]; then
                prompt_workflows=true
                prompt_credentials=true
                prompt_environment=true
            else
                if [[ "$workflows_source" == "default" ]]; then
                    prompt_workflows=true
                fi
                if [[ "$credentials_source" == "default" ]]; then
                    prompt_credentials=true
                fi
                if [[ "$environment_source" == "default" ]]; then
                    prompt_environment=true
                fi
            fi

            if [[ "$prompt_workflows" == true ]] || [[ "$prompt_credentials" == true ]] || [[ "$prompt_environment" == true ]]; then
                log INFO "Configure backup storage locations:"
            fi

            if [[ "$prompt_workflows" == true ]]; then
                select_workflows_storage
                workflows_source="interactive"
            fi

            if [[ "$prompt_credentials" == true ]]; then
                select_credentials_storage
                credentials_source="interactive"
            fi

            if [[ "$prompt_environment" == true ]]; then
                select_environment_storage
                environment_source="interactive"
            fi

            if [[ "$prompt_workflows" == true ]] || [[ "$prompt_credentials" == true ]] || [[ "$prompt_environment" == true ]]; then
                log INFO "Selected: Workflows=($workflows) $(format_storage_value $workflows), Credentials=($credentials) $(format_storage_value $credentials), Environment=($environment) $(format_storage_value $environment)"
            fi

            local needs_local_path_prompt=false
            local has_local_storage=false
            if [[ "$workflows" == "1" ]] || [[ "$credentials" == "1" ]] || [[ "$environment" == "1" ]]; then
                has_local_storage=true
            fi

            if [[ "$has_local_storage" == true ]]; then
                if [[ "$reconfigure_mode" == "true" ]]; then
                    needs_local_path_prompt=true
                elif [[ "$local_backup_path_source" == "default" ]] || [[ "$prompt_workflows" == true ]] || [[ "$prompt_credentials" == true ]] || [[ "$prompt_environment" == true ]]; then
                    needs_local_path_prompt=true
                fi
            fi

            if [[ "$needs_local_path_prompt" == true ]]; then
                printf "Local backup directory [${local_backup_path}]: "
                read -r custom_backup_path
                if [[ -n "$custom_backup_path" ]]; then
                    if [[ "$custom_backup_path" =~ ^~ ]]; then
                        custom_backup_path="${custom_backup_path/#\~/$HOME}"
                    fi
                    local_backup_path="$custom_backup_path"
                    local_backup_path_source="interactive"
                    log INFO "Using local backup directory: $local_backup_path"
                fi
            fi

            local needs_rotation_prompt=false
            if [[ "$has_local_storage" == true ]]; then
                if [[ "$reconfigure_mode" == "true" ]]; then
                    needs_rotation_prompt=true
                elif [[ "$local_rotation_limit_source" == "default" ]]; then
                    needs_rotation_prompt=true
                fi
            fi

            if [[ "$needs_rotation_prompt" == true ]]; then
                while true; do
                    printf "Local backup rotation limit [${local_rotation_limit}]: "
                    read -r rotation_input
                    rotation_input=${rotation_input:-$local_rotation_limit}
                    if [[ "$rotation_input" =~ ^(0|[0-9]+|unlimited)$ ]]; then
                        local_rotation_limit="$rotation_input"
                        local_rotation_limit_source="interactive"
                        break
                    else
                        log ERROR "Invalid rotation value. Use 0, a positive number, or 'unlimited'."
                    fi
                done
            fi

            # Ask about n8n folder structure if workflows are going to remote
            if [[ "$workflows" == "2" ]] && ([[ "$folder_structure_source" == "default" ]] || [[ "$reconfigure_mode" == "true" ]] || [[ "$prompt_workflows" == true ]]); then
                printf "Create n8n folder structure in Git repository? (yes/no) [no]: "
                read -r folder_structure_choice
                if [[ "$folder_structure_choice" == "yes" || "$folder_structure_choice" == "y" ]]; then
                    folder_structure=true
                else
                    folder_structure=false
                fi
                folder_structure_source="interactive"

                if [[ "$folder_structure" == "true" ]]; then
                    if [[ -z "$n8n_base_url" ]] || [[ "$reconfigure_mode" == "true" ]]; then
                        printf "n8n base URL (e.g., http://localhost:5678): "
                        read -r n8n_url
                        if [[ -n "$n8n_url" ]]; then
                            n8n_base_url="$n8n_url"
                        else
                            log ERROR "n8n base URL is required for folder structure"
                            exit 1
                        fi
                    fi

                    if [[ -z "$n8n_api_key" ]] || [[ "$reconfigure_mode" == "true" ]]; then
                        printf "n8n API key (leave blank to use stored Basic Auth credential): "
                        read -r -s n8n_api_key_input
                        echo
                        if [[ -n "$n8n_api_key_input" ]]; then
                            n8n_api_key="$n8n_api_key_input"
                        else
                            n8n_api_key=""
                        fi
                    fi

                    if [[ -z "$n8n_api_key" ]]; then
                        local default_cred_name="${n8n_session_credential:-N8N REST BACKUP}"
                        if [[ -z "$n8n_session_credential" ]] || [[ "$reconfigure_mode" == "true" ]]; then
                            printf "n8n credential name for session auth [${default_cred_name}]: "
                            read -r credential_name_input
                            credential_name_input=${credential_name_input:-$default_cred_name}
                            n8n_session_credential="$credential_name_input"
                        fi
                    elif [[ "$reconfigure_mode" == "true" ]]; then
                        n8n_session_credential=""
                    fi

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
                    fi

                    log SUCCESS "✅ n8n API configuration validated successfully!"
                    log INFO "✅ Folder structure enabled with n8n API integration"
                fi
            fi

            # Decide whether to prompt for encrypted credential exports
            if [[ "$credentials" != "0" ]]; then
                if [[ "$assume_defaults" == "true" ]]; then
                    if [[ -z "$credentials_encrypted" ]]; then
                        credentials_encrypted=true
                        credentials_encrypted_source="defaults"
                    fi
                    log DEBUG "Defaults mode enabled - keeping credentials encrypted without prompting."
                else
                    local prompt_encryption=false
                    if [[ "$reconfigure_mode" == "true" ]]; then
                        prompt_encryption=true
                    elif [[ "$credentials_encrypted_source" == "default" ]]; then
                        prompt_encryption=true
                    fi

                    if [[ "$prompt_encryption" == true ]]; then
                        local encryption_default_label="yes"
                        if [[ "${credentials_encrypted:-true}" == "false" ]]; then
                            encryption_default_label="no"
                        fi

                        printf "Export credentials encrypted by n8n (recommended)? (yes/no) [%s]: " "$encryption_default_label"
                        local encryption_choice
                        read -r encryption_choice
                        encryption_choice=${encryption_choice:-$encryption_default_label}

                        if [[ "$encryption_choice" == "yes" || "$encryption_choice" == "y" ]]; then
                            credentials_encrypted=true
                            credentials_encrypted_source="interactive"
                        else
                            # Warn user about decrypted exports
                            log WARN "⚠️  Credentials will be exported in decrypted form. Keep the files extremely secure."
                            if [[ "$credentials" == "2" ]]; then
                                printf "Decrypted credentials would be stored in Git history. Continue? (yes/no) [no]: "
                                local decrypted_confirm
                                read -r decrypted_confirm
                                decrypted_confirm=${decrypted_confirm:-no}
                                if [[ "$decrypted_confirm" == "yes" || "$decrypted_confirm" == "y" ]]; then
                                    credentials_encrypted=false
                                    credentials_encrypted_source="interactive"
                                    log WARN "⚠️  Proceeding with decrypted credentials for Git storage."
                                else
                                    credentials_encrypted=true
                                    credentials_encrypted_source="interactive"
                                    log INFO "Using encrypted credential export instead."
                                fi
                            else
                                credentials_encrypted=false
                                credentials_encrypted_source="interactive"
                            fi
                        fi
                    fi
                fi
            fi
        fi

        # Recalculate derived GitHub requirement after interactive choices
        if [[ "$action" == "restore" ]]; then
            needs_github=true
        else
            if [[ "$workflows" == "2" ]] || [[ "$credentials" == "2" ]]; then
                needs_github=true
            else
                needs_github=false
            fi
        fi

        # Offer dry-run selection when value came from defaults or during reconfigure
        if [[ "$dry_run_source" == "default" ]] || [[ "$reconfigure_mode" == "true" ]]; then
            local dry_run_default_label="no"
            if [[ "$dry_run" == "true" ]]; then
                dry_run_default_label="yes"
            fi
            printf "Run in dry-run mode (no changes will be made)? (yes/no) [%s]: " "$dry_run_default_label"
            local dry_run_choice
            read -r dry_run_choice
            dry_run_choice=${dry_run_choice:-$dry_run_default_label}
            if [[ "$dry_run_choice" == "yes" || "$dry_run_choice" == "y" ]]; then
                dry_run=true
            else
                dry_run=false
            fi
            dry_run_source="interactive"
        fi

        # Get GitHub config only if needed
        if [[ $needs_github == true ]]; then
            get_github_config "$reconfigure_mode"
            if [[ "$action" == "backup" ]]; then
                local prompt_github_path=false
                if [[ "$reconfigure_mode" == "true" ]]; then
                    prompt_github_path=true
                elif [[ "$github_path_source" == "default" ]]; then
                    prompt_github_path=true
                fi

                if [[ "$prompt_github_path" == true ]]; then
                    prompt_github_path_prefix
                else
                    if [[ -n "$github_path" ]]; then
                        log INFO "GitHub backups will use existing path prefix: $github_path"
                    else
                        log INFO "GitHub backups will use the repository root."
                    fi
                fi
            fi
        else
            log INFO "🏠 Local-only backup - no GitHub configuration needed"
            github_token=""
            github_repo=""
            github_branch="main"
        fi
        
        if [[ "$action" == "restore" ]]; then
            RESTORE_APPLY_FOLDER_STRUCTURE="${restore_folder_structure_preference:-false}"
            RESTORE_APPLY_FOLDER_STRUCTURE_SOURCE="${restore_folder_structure_preference_source:-default}"
            select_restore_type
            restore_type="$SELECTED_RESTORE_TYPE"
            restore_workflows_mode="$RESTORE_WORKFLOWS_MODE"
            restore_credentials_mode="$RESTORE_CREDENTIALS_MODE"
            restore_folder_structure_preference="$RESTORE_APPLY_FOLDER_STRUCTURE"
            restore_folder_structure_preference_source="$RESTORE_APPLY_FOLDER_STRUCTURE_SOURCE"

            if [[ "$restore_workflows_mode" == "2" || "$restore_credentials_mode" == "2" ]]; then
                needs_github=true
            else
                needs_github=false
            fi
        fi
        
        # Derive convenience flags from numeric storage settings (avoid repeated comparisons)
        needs_local_path=false
        
        # Check if local path is needed (for any local storage)
        if [[ "$workflows" == "1" ]] || [[ "$credentials" == "1" ]]; then 
            needs_local_path=true 
        fi
        
        log DEBUG "Storage settings - workflows: ($workflows) $(format_storage_value $workflows), credentials: ($credentials) $(format_storage_value $credentials), needs_github: $needs_github"
    fi

    # Normalize boolean values after configuration and prompts
    dry_run=${dry_run:-false}
    verbose=${verbose:-false}
    dated_backups=${dated_backups:-false}
    folder_structure=${folder_structure:-false}

    dry_run_flag=false
    if [[ "$dry_run" == "true" ]]; then
        dry_run_flag=true
    fi

    verbose_flag=false
    if [[ "$verbose" == "true" ]]; then
        verbose_flag=true
    fi

    dated_backups_flag=false
    if [[ "$dated_backups" == "true" ]]; then
        dated_backups_flag=true
    fi

    folder_structure_enabled=false
    if [[ "$folder_structure" == "true" ]]; then
        folder_structure_enabled=true
    fi

    if [[ $dry_run_flag == true ]]; then
        local dry_run_origin="${dry_run_source:-unknown}"
        log WARN "DRY RUN MODE ENABLED (source: $dry_run_origin)"
    fi

    if [[ $verbose_flag == true ]]; then
        log DEBUG "Verbose mode enabled."
    fi

    log DEBUG "Boolean flags - dated_backups: $dated_backups_flag, dry_run: $dry_run_flag, folder_structure: $folder_structure_enabled"
    log DEBUG "GitHub required: $needs_github"

    # Final validation
    if [ -z "$action" ] || [ -z "$container" ]; then
        log ERROR "Missing required parameters (Action, Container). Exiting."
        exit 1
    fi
    
    # For remote operations, GitHub parameters are required
    if [[ $needs_github == true ]]; then
        if [ -z "$github_token" ] || [ -z "$github_repo" ] || [ -z "$github_branch" ]; then
            log ERROR "Missing required GitHub parameters (Token, Repo, Branch) for remote operations. Exiting."
            exit 1
        fi
    fi

    # Perform GitHub API pre-checks only when needed
    if $needs_github; then
        if ! check_github_access "$github_token" "$github_repo" "$github_branch" "$action"; then
            log ERROR "GitHub access pre-checks failed. Aborting."
            exit 1
        fi
    else
        log INFO "✅ Local-only operation - skipping GitHub validation"
    fi

    # Execute the requested action
    log INFO "Starting action: $action"
    case "$action" in
        backup)
            if backup "$container" "$github_token" "$github_repo" "$github_branch" "$dated_backups_flag" "$dry_run_flag" "$workflows" "$credentials" "$folder_structure_enabled" "$local_backup_path" "$local_rotation_limit" "$credentials_folder_name"; then
                log SUCCESS "Backup operation completed successfully."
                if [[ "$interactive_mode" == true ]] && [[ "$dry_run_flag" != true ]] && [[ "$credentials" != "0" ]] && [[ "${credentials_encrypted:-true}" != "false" ]]; then
                    local encryption_key=""
                    if encryption_key=$(docker exec "$container" sh -c 'printenv N8N_ENCRYPTION_KEY' 2>/dev/null | tr -d '\r'); then
                        :
                    else
                        encryption_key=""
                    fi

                    if [[ -z "$encryption_key" ]]; then
                        local config_json=""
                        if ! config_json=$(docker exec "$container" sh -c 'cat /home/node/.n8n/config' 2>/dev/null); then
                            config_json=""
                        fi
                        if [[ -z "$config_json" ]]; then
                            if ! config_json=$(docker exec "$container" sh -c 'cat /home/node/.n8n/config.json' 2>/dev/null); then
                                config_json=""
                            fi
                        fi
                        if [[ -n "$config_json" ]]; then
                            encryption_key=$(printf '%s' "$config_json" | jq -r '.encryptionKey // empty' 2>/dev/null | tr -d '\r') || encryption_key=""
                        fi
                    fi

                    if [[ -n "$encryption_key" ]]; then
                        printf "\n%s[SECURITY]%s Encryption key for exported credentials: %s\n" "$YELLOW" "$NC" "$encryption_key"
                        printf "%sIMPORTANT:%s Store this key securely; it's required to decrypt your credential backups.\n" "$RED" "$NC"
                        printf "%sNote:%s The key is also captured in the local .env backup if environment exports are enabled.\n\n" "$BLUE" "$NC"
                    else
                        log WARN "Unable to retrieve N8N_ENCRYPTION_KEY from container. If the key was generated automatically, run 'docker exec -it $container sh -c "cat /home/node/.n8n/config"' (or the .json variant) and copy the 'encryptionKey' value."
                    fi
                fi
            else
                log ERROR "Backup operation failed."
                exit 1
            fi
            ;;
        restore)
          if restore "$container" "$github_token" "$github_repo" "$github_branch" "${restore_workflows_mode:-2}" "${restore_credentials_mode:-1}" "${restore_folder_structure_preference:-false}" "$dry_run_flag" "$credentials_folder_name"; then
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
trap 'log ERROR "An unexpected error occurred (Line: $LINENO). Aborting."; exit 1' ERR
main "$@"
exit 0