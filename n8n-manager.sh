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
# Control flags
dry_run=""     # empty = unset, true/false = explicitly configured
verbose=""     # empty = unset, true/false = explicitly configured
needs_github="" # tracks if GitHub access is required

# Git/GitHub settings  
github_token=""
github_repo=""
github_branch="main"
dated_backups=""  # empty = unset, true/false = explicitly configured

# Storage settings (handled by numeric config)
workflows=""              # empty = unset, 0=disabled, 1=local, 2=remote
credentials=""            # empty = unset, 0=disabled, 1=local, 2=remote
local_backup_path="$HOME/n8n-backup"
local_rotation_limit="10"

# Advanced features
folder_structure=""            # empty = unset, true/false = explicitly configured
n8n_base_url=""               # Required if folder_structure=true
n8n_api_key=""                # Optional - session auth used if empty
n8n_email=""                  # Optional - for session auth
n8n_password=""               # Optional - for session auth

# Logging and misc
log_file=""                # Custom log file path
restore_type="all"            # all|workflows|credentials
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
            --dated) dated_backups=true; shift 1 ;;
                        --workflows)
                case "${2,,}" in  # Convert to lowercase
                    0|disabled) workflows=0; shift 2 ;;
                    1|local) workflows=1; shift 2 ;;
                    2|remote) workflows=2; shift 2 ;;
                    *) log ERROR "Invalid workflows value: $2. Must be 0/disabled, 1/local, or 2/remote"
                       exit 1 ;;
                esac
                ;;
            --credentials)
                case "${2,,}" in  # Convert to lowercase
                    0|disabled) credentials=0; shift 2 ;;
                    1|local) credentials=1; shift 2 ;;
                    2|remote) credentials=2; shift 2 ;;
                    *) log ERROR "Invalid credentials value: $2. Must be 0/disabled, 1/local, or 2/remote"
                       exit 1 ;;
                esac
                ;;
            --path) local_backup_path="$2"; shift 2 ;;
            --rotation)
                if [[ -n "$2" && "$2" != -* ]]; then
                    local_rotation_limit="$2"; shift 2
                else
                    echo -e "${YELLOW}[INFO]${NC}   Valid rotation options:" >&2
                    echo -e "${YELLOW}[INFO]${NC}   • 0          - No rotation (overwrite current backup)" >&2
                    echo -e "${YELLOW}[INFO]${NC}   • <number>   - Keep N most recent backups (creates archive/timestamp dirs)" >&2
                    echo -e "${YELLOW}[INFO]${NC}   • unlimited  - Keep all backups (no deletion)" >&2
                    echo -e "${RED}[ERROR]${NC} Missing required argument for --rotation" >&2
                    exit 1
                fi
                ;;
            --restore-type)
                if [[ "$2" =~ ^(all|workflows|credentials)$ ]]; then
                    restore_type="$2"
                    shift 2
                else
                    echo -e "${RED}[ERROR]${NC} Invalid restore type: $2. Valid options: all, workflows, credentials" >&2
                    exit 1
                fi
                ;;
            --dry-run) dry_run=true; shift 1 ;; 
            --verbose) verbose=true; shift 1 ;; 
            --log-file) log_file="$2"; shift 2 ;; 
            --folder-structure) folder_structure=true; shift 1 ;;
            --n8n-url) n8n_base_url="$2"; shift 2 ;;
            --n8n-api-key) n8n_api_key="$2"; shift 2 ;;
            -h|--help) show_help; exit 0 ;;
            *) echo "[ERROR] Invalid option: $1"; show_help; exit 1 ;;
        esac
    done

    # Load config file (must happen after parsing args)
    load_config

    log HEADER "n8n Backup/Restore Manager v$VERSION"
    # Initialize flags before use
    dry_run_flag=false
    verbose_flag=false
    if [[ "${dry_run:-false}" == "true" ]]; then dry_run_flag=true; fi
    if [[ "${verbose:-false}" == "true" ]]; then verbose_flag=true; fi
    
    log INFO "🚀 Flexible backup storage: local files or Git repository"
    if [[ $dry_run_flag == true ]]; then log WARN "DRY RUN MODE ENABLED"; fi
    if [[ $verbose_flag == true ]]; then log DEBUG "Verbose mode enabled."; fi
    
    check_host_dependencies

    # Runtime variables are now lowercase and used directly
    log DEBUG "Action: $action, Container: $container, Repo: $github_repo"
    log DEBUG "Branch: $github_branch, Workflows: ($workflows) $(format_storage_value $workflows), Credentials: ($credentials) $(format_storage_value $credentials)"
    log DEBUG "Local Path: $local_backup_path, Rotation: $local_rotation_limit"
    
    # Calculate if GitHub access is needed
    needs_github=false
    if [[ "$action" == "restore" ]] || [[ "$workflows" == "2" ]] || [[ "$credentials" == "2" ]]; then 
        needs_github=true 
    fi
    log DEBUG "GitHub required: $needs_github"
    
    # Set intelligent defaults for backup (only if not already configured)
    if [[ "$action" == "backup" ]]; then
        # Check if both are disabled after config loading
        if [[ "$workflows" == "0" && "$credentials" == "0" ]]; then
            log ERROR "Both workflows and credentials are disabled. Nothing to backup!"
            log INFO "Please specify backup options:"
            log INFO "  --workflows 1 --credentials 1     (both stored locally - secure)"
            log INFO "  --workflows 2 --credentials 1     (workflows to Git, credentials local)"
            log INFO "  --workflows 1 --credentials 2     (workflows local, credentials to Git)"
            log INFO "  --workflows 2 --credentials 2     (both to Git - less secure)"
            log INFO "  --workflows 1                     (workflows local only, skip credentials)"
            log INFO "  --credentials 1                   (credentials local only, skip workflows)"
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
    log DEBUG "Branch: $github_branch, Workflows: ($workflows) $(format_storage_value $workflows), Credentials: ($credentials) $(format_storage_value $credentials)"
    log DEBUG "Local Path: $local_backup_path, Rotation: $local_rotation_limit"

    # Check if running non-interactively
    if ! [ -t 0 ]; then
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
            
            # Validate API access
            log INFO "Validating n8n API access..."
            if ! validate_n8n_api_access "$n8n_base_url" "$n8n_api_key"; then
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
        
        # Interactive dated backup prompt (only if not configured or in reconfigure mode)
        if [[ "$action" == "backup" ]] && ([[ -z "$dated_backups" ]] || [[ "$reconfigure_mode" == "true" ]]); then
             printf "Create a dated backup (in a timestamped subdirectory)? (yes/no) [no]: "
             local confirm_dated
             read -r confirm_dated
             if [[ "$confirm_dated" == "yes" || "$confirm_dated" == "y" ]]; then
                 dated_backups=true
             else
                 dated_backups=false
             fi
        fi
        log DEBUG "Use Dated Backup: $dated_backups"
        
        # Interactive storage configuration using new selection functions
        if [[ "$action" == "backup" ]] && ([[ "$workflows" == "0" && "$credentials" == "0" ]] || [[ "$reconfigure_mode" == "true" ]]); then
            log INFO "Configure backup storage locations:"
            
            # Use new interactive storage selection functions
            select_workflows_storage
            select_credentials_storage
            
            log INFO "Selected: Workflows=($workflows) $(format_storage_value $workflows), Credentials=($credentials) $(format_storage_value $credentials)"
            
            # Ask for local backup directory if local storage is needed
            if [[ "$workflows" == "1" || "$credentials" == "1" ]]; then
                printf "Local backup directory [~/n8n-backup]: "
                read -r custom_backup_path
                if [[ -n "$custom_backup_path" ]]; then
                    if [[ "$custom_backup_path" =~ ^~ ]]; then
                        custom_backup_path="${custom_backup_path/#\~/$HOME}"
                    fi
                    local_backup_path="$custom_backup_path"
                    log INFO "Using custom local backup directory: $local_backup_path"
                fi
            fi
            
            # Ask about n8n folder structure if workflows are going to remote
            if [[ "$workflows" == "2" ]] && ([[ -z "$folder_structure" ]] || [[ "$reconfigure_mode" == "true" ]]); then
                printf "Create n8n folder structure in Git repository? (yes/no) [no]: "
                read -r folder_structure_choice
                if [[ "$folder_structure_choice" == "yes" || "$folder_structure_choice" == "y" ]]; then
                    folder_structure=true
                else
                    folder_structure=false
                fi
                    
                # Prompt for n8n API credentials if not already configured or in reconfigure mode
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
                    printf "n8n API key (leave blank to use email/password login): "
                    read -r -s n8n_api_key_input
                    echo  # Add newline after hidden input
                    if [[ -n "$n8n_api_key_input" ]]; then
                        n8n_api_key="$n8n_api_key_input"
                    else
                        log INFO "No API key provided - will use session authentication"
                        n8n_api_key=""  # Explicitly set to empty
                    fi
                fi
                
                # Validate API access immediately after configuration
                log INFO "Validating n8n API access..."
                if ! validate_n8n_api_access "$n8n_base_url" "$n8n_api_key"; then
                    log ERROR "❌ n8n API validation failed!"
                    log ERROR "Authentication failed with all available methods."
                    log ERROR "Cannot proceed with folder structure creation."
                    log INFO "💡 Please verify:"
                    log INFO "   1. n8n instance is running and accessible"
                    log INFO "   2. Credentials (API key or email/password) are correct"
                    log INFO "   3. No authentication barriers blocking access"
                    exit 1
                fi
                
                log SUCCESS "✅ n8n API configuration validated successfully!"
                
                log INFO "✅ Folder structure enabled with n8n API integration"
            fi
        fi
        
        # Get GitHub config only if needed
        if [[ $needs_github == true ]]; then
            get_github_config "$reconfigure_mode"
        else
            log INFO "🏠 Local-only backup - no GitHub configuration needed"
            github_token=""
            github_repo=""
            github_branch="main"
        fi
        
        # Interactive restore type selection
        if [[ "$action" == "restore" ]] && ([[ "$restore_type" == "all" ]] || [[ "$reconfigure_mode" == "true" ]]); then
            select_restore_type
            restore_type="$SELECTED_RESTORE_TYPE"
        elif [[ "$action" == "restore" ]]; then
             log INFO "Using restore type: $restore_type"
        fi
        
        # Set defaults for any boolean variables still empty after interactive prompts
        dated_backups=${dated_backups:-false}
        folder_structure=${folder_structure:-false}
        verbose=${verbose:-false}
        dry_run=${dry_run:-false}
        
        # Derive convenience flags from numeric storage settings (avoid repeated comparisons)
        needs_local_path=false
        
        # Check if local path is needed (for any local storage)
        if [[ "$workflows" == "1" ]] || [[ "$credentials" == "1" ]]; then 
            needs_local_path=true 
        fi
        
        # Convert remaining string boolean variables to boolean flags (avoid repeated string comparisons)
        dated_backups_flag=false
        folder_structure_flag=false
        
        if [[ "$dated_backups" == "true" ]]; then dated_backups_flag=true; fi
        if [[ "$folder_structure" == "true" ]]; then folder_structure_flag=true; fi
        use_dated_backup_flag=$dated_backups_flag
        
        log DEBUG "Storage settings - workflows: ($workflows) $(format_storage_value $workflows), credentials: ($credentials) $(format_storage_value $credentials), needs_github: $needs_github"
        log DEBUG "Boolean flags - dated_backups: $dated_backups_flag, dry_run: $dry_run_flag, folder_structure: $folder_structure_flag"
    fi

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
            if backup "$container" "$github_token" "$github_repo" "$github_branch" "$dated_backups_flag" "$dry_run_flag" "$workflows" "$credentials" "$folder_structure_flag" "$local_backup_path" "$local_rotation_limit"; then
                log SUCCESS "Backup operation completed successfully."
            else
                log ERROR "Backup operation failed."
                exit 1
            fi
            ;;
        restore)
            if restore "$container" "$github_token" "$github_repo" "$github_branch" "$restore_type" "$dry_run_flag"; then
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