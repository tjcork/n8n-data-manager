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
CONFIG_FILE_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/n8n-manager/config"

# --- Global Configuration Variables ---
VERSION="4.1.0"
DEBUG_TRACE=${DEBUG_TRACE:-false}

# Selected values from interactive mode
SELECTED_ACTION=""
SELECTED_CONTAINER_ID=""
GITHUB_TOKEN=""
GITHUB_REPO=""
GITHUB_BRANCH="main"
DEFAULT_CONTAINER=""
SELECTED_RESTORE_TYPE="all"

# Command-line argument variables
ARG_ACTION=""
ARG_CONTAINER=""
ARG_TOKEN=""
ARG_REPO=""
ARG_BRANCH=""
ARG_CONFIG_FILE=""
ARG_DATED_BACKUPS=false
ARG_WORKFLOWS_STORAGE=""
ARG_CREDENTIALS_STORAGE=""
ARG_LOCAL_BACKUP_PATH=""
ARG_LOCAL_ROTATION_LIMIT=""
ARG_RESTORE_TYPE="all"
ARG_DRY_RUN=false
ARG_VERBOSE=false
ARG_LOG_FILE=""
ARG_FOLDER_STRUCTURE=false
ARG_N8N_BASE_URL=""
ARG_N8N_API_KEY=""

# Configuration file variables (loaded by modules)
CONF_LOCAL_ROTATION_LIMIT=""
CONF_DATED_BACKUPS=false
CONF_VERBOSE=false
CONF_LOG_FILE=""
CONF_FOLDER_STRUCTURE=false
CONF_N8N_BASE_URL=""
CONF_N8N_API_KEY=""

# Load all modules
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/interactive.sh" 
source "$SCRIPT_DIR/lib/n8n-api.sh"
source "$SCRIPT_DIR/lib/backup.sh"
source "$SCRIPT_DIR/lib/restore.sh"

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
                    ARG_WORKFLOWS_STORAGE="local"; shift 1
                fi ;;
            --credentials)
                if [ $# -gt 1 ] && [[ "$2" == "local" || "$2" == "remote" ]]; then
                    ARG_CREDENTIALS_STORAGE="$2"; shift 2
                else
                    ARG_CREDENTIALS_STORAGE="local"; shift 1
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
    log INFO "🚀 Flexible backup storage: local files or Git repository"
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
    local local_rotation_limit="${ARG_LOCAL_ROTATION_LIMIT:-10}"
    local restore_type="${ARG_RESTORE_TYPE:-all}"
    local is_dry_run=$ARG_DRY_RUN
    
    # Set intelligent defaults for backup
    if [[ "$action" == "backup" ]]; then
        if [[ -z "$workflows_storage" && -z "$credentials_storage" ]]; then
            log ERROR "No storage options specified. Please specify --workflows and/or --credentials with 'local' or 'remote'"
            log INFO "Examples:"
            log INFO "  --workflows remote --credentials local    (workflows to Git, credentials local)"
            log INFO "  --workflows local --credentials local     (both local only)"
            log INFO "  --workflows remote                        (workflows to Git only)"
            log INFO "  --credentials local                       (credentials local only)"
            exit 1
        elif [[ -z "$workflows_storage" ]]; then
            workflows_storage="remote"
            log INFO "Workflows storage not specified - defaulting to remote (Git repository)"
        elif [[ -z "$credentials_storage" ]]; then
            credentials_storage="local"
            log INFO "Credentials storage not specified - defaulting to local (secure)"
        fi
    fi

    # Debug logging
    log DEBUG "Action: $action, Container: $container_id, Repo: $github_repo"
    log DEBUG "Branch: $branch, Workflows: $workflows_storage, Credentials: $credentials_storage"
    log DEBUG "Local Path: $local_backup_path, Rotation: $local_rotation_limit"

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

        # Validate container
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
        
        # Interactive action selection
        if [ -z "$action" ]; then 
            select_action
            action="$SELECTED_ACTION"
        fi
        log DEBUG "Action selected: $action"
        
        # Interactive container selection
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
        
        # Interactive dated backup prompt
        if [[ "$action" == "backup" ]] && ! $use_dated_backup && ! grep -q "CONF_DATED_BACKUPS=true" "${ARG_CONFIG_FILE:-$CONFIG_FILE_PATH}" 2>/dev/null; then
             printf "Create a dated backup (in a timestamped subdirectory)? (yes/no) [no]: "
             local confirm_dated
             read -r confirm_dated
             if [[ "$confirm_dated" == "yes" || "$confirm_dated" == "y" ]]; then
                 use_dated_backup=true
             fi
        fi
        log DEBUG "Use Dated Backup: $use_dated_backup"
        
        # Interactive storage configuration
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
        
        # Get GitHub config only if needed
        if [[ "$action" == "restore" ]] || [[ "$workflows_storage" == "remote" ]] || [[ "$credentials_storage" == "remote" ]]; then
            get_github_config
            github_token="$GITHUB_TOKEN"
            github_repo="$GITHUB_REPO"
            branch="$GITHUB_BRANCH"
        else
            log INFO "🏠 Local-only backup - no GitHub configuration needed"
            github_token=""
            github_repo=""
            branch="main"
        fi
        
        # Interactive restore type selection
        if [[ "$action" == "restore" ]] && [[ "$restore_type" == "all" ]] && ! grep -q "CONF_RESTORE_TYPE=" "${ARG_CONFIG_FILE:-$CONFIG_FILE_PATH}" 2>/dev/null; then
            select_restore_type
            restore_type="$SELECTED_RESTORE_TYPE"
        elif [[ "$action" == "restore" ]]; then
             log INFO "Using restore type: $restore_type"
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

    # Execute the requested action
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
trap 'log ERROR "An unexpected error occurred (Line: $LINENO). Aborting."; exit 1' ERR
main "$@"
exit 0