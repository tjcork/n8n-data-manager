#!/usr/bin/env bash
# =========================================================
# lib/restore.sh - Restore operations for n8n-manager
# =========================================================
# All restore-related functions: restore process, rollback

# Source required modules
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/n8n-api.sh"
source "$(dirname "${BASH_SOURCE[0]}")/restore/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/restore/manifest.sh"
source "$(dirname "${BASH_SOURCE[0]}")/restore/staging.sh"
source "$(dirname "${BASH_SOURCE[0]}")/restore/folders.sh"
source "$(dirname "${BASH_SOURCE[0]}")/restore/validate.sh"


SNAPSHOT_EXISTING_WORKFLOWS_PATH=""

readonly WORKFLOW_COUNT_FILTER=$(cat <<'JQ'
def to_array:
    if type == "array" then .
    elif type == "object" then
        if (has("data") and (.data | type == "array")) then .data
        elif (has("workflows") and (.workflows | type == "array")) then .workflows
        elif (has("items") and (.items | type == "array")) then .items
        else [.] end
    else [] end;
to_array
| map(select(
        (type == "object") and (
            (((.resource // .type // "") | tostring | ascii_downcase) == "workflow")
            or (.nodes? | type == "array")
        )
    ))
| length
JQ
)

restore() {
    local container_id="$1"
    local github_token="$2"
    local github_repo="$3"
    local branch="$4"
    local workflows_mode="${5:-2}"
    local credentials_mode="${6:-1}"
    local apply_folder_structure="${7:-auto}"
    local is_dry_run=${8:-false}
    local credentials_folder_name="${9:-.credentials}"
    local interactive_mode="${10:-false}"
    local preserve_ids="${11:-false}"
    local no_overwrite="${12:-false}"
    local folder_structure_backup=false
    local download_dir=""
    local repo_workflows=""
    local structured_workflows_dir=""
    local resolved_structured_dir=""
    local staged_manifest_file=""
    local repo_credentials=""
    local selected_base_dir=""
    local keep_api_session_alive="false"
    local selected_backup=""
    local dated_backup_found=false
    preserve_ids=$(printf '%s' "$preserve_ids" | tr '[:upper:]' '[:lower:]')
    if [[ "$preserve_ids" != "true" ]]; then
        preserve_ids="false"
    fi
    local preserve_ids_requested="$preserve_ids"

    no_overwrite=$(printf '%s' "$no_overwrite" | tr '[:upper:]' '[:lower:]')
    if [[ "$no_overwrite" == "true" ]]; then
        no_overwrite="true"
        preserve_ids="false"
    else
        no_overwrite="false"
    fi

    if [[ "$workflows_mode" != "0" ]]; then
        if [[ "$no_overwrite" == "true" ]]; then
            log INFO "Workflow restore will always assign new workflow IDs (--no-overwrite enabled)."
            if [[ "$preserve_ids_requested" == "true" ]]; then
                log DEBUG "--no-overwrite overrides requested workflow ID preservation."
            fi
        elif [[ "$preserve_ids" == "true" ]]; then
            log INFO "Workflow restore will attempt to preserve existing workflow IDs when possible."
        else
            log INFO "Workflow restore will reuse workflow IDs when safe and mint new ones only if conflicts arise."
        fi
    fi

    local local_backup_dir="$HOME/n8n-backup"
    local local_workflows_file="$local_backup_dir/workflows.json"
    local local_credentials_file="$local_backup_dir/credentials.json"
    local requires_remote=false

    credentials_folder_name="${credentials_folder_name%/}"
    if [[ -z "$credentials_folder_name" ]]; then
        credentials_folder_name=".credentials"
    fi
    local credentials_git_relative_dir
    credentials_git_relative_dir="$(compose_repo_storage_path "$credentials_folder_name")"
    credentials_git_relative_dir="${credentials_git_relative_dir#/}"
    credentials_git_relative_dir="${credentials_git_relative_dir%/}"
    if [[ -z "$credentials_git_relative_dir" ]]; then
        credentials_git_relative_dir="$credentials_folder_name"
    fi
    local credentials_subpath="$credentials_git_relative_dir/credentials.json"

    local project_storage_relative
    project_storage_relative="$(compose_repo_storage_path "$project_slug")"
    project_storage_relative="${project_storage_relative#/}"
    project_storage_relative="${project_storage_relative%/}"

    local restore_scope="none"
    if [[ "$workflows_mode" != "0" && "$credentials_mode" != "0" ]]; then
        restore_scope="all"
    elif [[ "$workflows_mode" != "0" ]]; then
        restore_scope="workflows"
    elif [[ "$credentials_mode" != "0" ]]; then
        restore_scope="credentials"
    fi

    log HEADER "Performing Restore (Workflows: $(format_storage_value $workflows_mode), Credentials: $(format_storage_value $credentials_mode))"
    if $is_dry_run; then log WARN "DRY RUN MODE ENABLED - NO CHANGES WILL BE MADE"; fi
    
    # Show restore plan for clarity
    # --- 1. Prepare backup sources based on selected modes ---
    log HEADER "Step 1: Preparing Backup Sources"

    if [[ "$workflows_mode" == "2" || "$credentials_mode" == "2" ]]; then
        requires_remote=true
    fi

    if $requires_remote; then
        download_dir=$(mktemp -d -t n8n-download-XXXXXXXXXX)
        log DEBUG "Created download directory: $download_dir"

        local git_repo_url="https://${github_token}@github.com/${github_repo}.git"
        local sparse_target=""
        if [[ -n "$github_path" ]]; then
            sparse_target="${github_path#/}"
            sparse_target="${sparse_target%/}"
        fi

        local -a git_clone_args=("--depth" "1" "--branch" "$branch")
        if [[ -n "$sparse_target" ]]; then
            git_clone_args+=("--filter=blob:none" "--no-checkout")
            if git clone -h 2>&1 | grep -q -- '--sparse'; then
                git_clone_args+=("--sparse")
            fi
        fi

        log INFO "Cloning repository $github_repo branch $branch..."
        local clone_args_display
        clone_args_display=$(printf '%s ' "${git_clone_args[@]}" "$git_repo_url" "$download_dir")
        clone_args_display="${clone_args_display% }"
        log DEBUG "Running: git clone ${clone_args_display}"
        if ! git clone "${git_clone_args[@]}" "$git_repo_url" "$download_dir"; then
            log ERROR "Failed to clone repository. Check URL, token, branch, and permissions."
            rm -rf "$download_dir"
            return 1
        fi

        selected_base_dir="$download_dir"

        cd "$download_dir" || {
            log ERROR "Failed to change to download directory"
            rm -rf "$download_dir"
            return 1
        }

        if [[ -n "$sparse_target" ]]; then
            log INFO "Restricting checkout to configured GitHub path: $sparse_target"
            local sparse_setup_failed=false
            if ! git sparse-checkout init --cone >/dev/null 2>&1; then
                log DEBUG "Sparse checkout init unavailable or already configured; attempting manual enablement."
                if ! git config core.sparseCheckout true >/dev/null 2>&1; then
                    sparse_setup_failed=true
                fi
            fi

            if ! $sparse_setup_failed; then
                if git sparse-checkout set "$sparse_target" >/dev/null 2>&1; then
                    if git checkout "$branch" >/dev/null 2>&1; then
                        log SUCCESS "Sparse checkout active for $sparse_target"
                    else
                        log WARN "Unable to finalize sparse checkout; falling back to full repository contents."
                        sparse_setup_failed=true
                    fi
                else
                    log WARN "Sparse checkout configuration failed; falling back to full repository contents."
                    sparse_setup_failed=true
                fi
            fi

            if $sparse_setup_failed; then
                git sparse-checkout disable >/dev/null 2>&1 || true
                if ! git checkout "$branch" >/dev/null 2>&1; then
                    log WARN "Fallback checkout failed; repository contents may be incomplete."
                fi
            fi
        fi

        local backup_dirs=()
        readarray -t backup_dirs < <(find . -type d -name "backup_*" | sort -r)

        if [ ${#backup_dirs[@]} -gt 0 ]; then
            log INFO "Found ${#backup_dirs[@]} dated backup(s):"

            if ! [ -t 0 ] || [[ "${assume_defaults:-false}" == "true" ]]; then
                selected_backup="${backup_dirs[0]}"
                dated_backup_found=true
                log INFO "Auto-selecting most recent backup in non-interactive mode: $selected_backup"
            else
                echo ""
                echo "Select a backup to restore:"
                echo "------------------------------------------------"
                echo "0) Use files from repository root (not a dated backup)"
                for i in "${!backup_dirs[@]}"; do
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

        if $dated_backup_found; then
            local dated_path="${selected_backup#./}"
            selected_base_dir="$download_dir/$dated_path"
            log INFO "Looking for files in dated backup: $dated_path"
        fi

        if [[ "$workflows_mode" == "2" ]]; then
            if [ -f "$selected_base_dir/.n8n-folder-structure.json" ]; then
                folder_structure_backup=true
                structured_workflows_dir="$(dirname "$selected_base_dir/.n8n-folder-structure.json")"
                log INFO "Detected workflow directory via legacy manifest: $structured_workflows_dir"
            else
                local legacy_manifest
                legacy_manifest=$(find "$selected_base_dir" -maxdepth 5 -type f -name ".n8n-folder-structure.json" | head -n 1)
                if [[ -n "$legacy_manifest" ]]; then
                    folder_structure_backup=true
                    structured_workflows_dir="$(dirname "$legacy_manifest")"
                    log INFO "Detected workflow directory via legacy manifest: $structured_workflows_dir"
                fi
            fi

            if [ -f "$selected_base_dir/workflows.json" ]; then
                repo_workflows="$selected_base_dir/workflows.json"
                log SUCCESS "Found workflows.json in selected backup"
            elif [ -f "$download_dir/workflows.json" ]; then
                repo_workflows="$download_dir/workflows.json"
                log SUCCESS "Found workflows.json in repository root"
            fi

            if [[ -z "$repo_workflows" ]]; then
                local candidate_struct_dir=""
                local -a structure_candidates=()
                if [[ -n "$project_storage_relative" ]]; then
                    structure_candidates+=("$selected_base_dir/$project_storage_relative")
                    structure_candidates+=("$download_dir/$project_storage_relative")
                fi
                structure_candidates+=("$selected_base_dir")
                structure_candidates+=("$download_dir")

                for candidate_dir in "${structure_candidates[@]}"; do
                    if [[ -z "$candidate_dir" || ! -d "$candidate_dir" ]]; then
                        continue
                    fi
                    if find "$candidate_dir" -type f -name "*.json" \
                        ! -path "*/.credentials/*" \
                        ! -path "*/archive/*" \
                        ! -name "credentials.json" \
                        ! -name "workflows.json" \
                        -print -quit >/dev/null 2>&1; then
                        candidate_struct_dir="$candidate_dir"
                        break
                    fi
                done

                if [[ -n "$candidate_struct_dir" ]]; then
                    folder_structure_backup=true
                    structured_workflows_dir="$candidate_struct_dir"
                    log INFO "Detected workflow directory: $candidate_struct_dir"
                fi
            fi
        fi

        if [[ "$credentials_mode" == "2" ]]; then
            local credential_candidates=()
            credential_candidates+=("$selected_base_dir/$credentials_subpath")
            credential_candidates+=("$selected_base_dir/credentials.json")
            credential_candidates+=("$download_dir/$credentials_subpath")
            credential_candidates+=("$download_dir/credentials.json")

            for candidate in "${credential_candidates[@]}"; do
                if [[ -n "$candidate" && -f "$candidate" ]]; then
                    repo_credentials="$candidate"
                    if [[ "$candidate" == *"/$credentials_subpath" ]]; then
                        log SUCCESS "Found credentials.json in configured folder: $candidate"
                    else
                        log WARN "Using legacy credentials.json location: $candidate"
                    fi
                    break
                fi
            done
        fi

        if [[ "$credentials_mode" != "0" && ( -z "$repo_credentials" || ! -f "$repo_credentials" ) ]]; then
            log WARN "Credentials file not found under '$credentials_git_relative_dir'. Skipping credential restore."
            credentials_mode="0"
        fi

        cd - >/dev/null 2>&1 || true
    else
        log INFO "Skipping Git fetch; relying on local backups only."
    fi

    if [[ "$workflows_mode" == "1" ]]; then
        if [ -f "$local_backup_dir/.n8n-folder-structure.json" ]; then
            folder_structure_backup=true
            structured_workflows_dir="$(dirname "$local_backup_dir/.n8n-folder-structure.json")"
            log INFO "Detected local workflow directory via legacy manifest: $structured_workflows_dir"
        fi

        if [[ -z "$repo_workflows" && -f "$local_workflows_file" ]]; then
            repo_workflows="$local_workflows_file"
            log INFO "Selected local workflows backup: $repo_workflows"
        fi

        if [[ -z "$repo_workflows" ]]; then
            local local_struct_dir=""
            if [[ -n "$project_storage_relative" ]]; then
                local candidate="$local_backup_dir/$project_storage_relative"
                if [[ -d "$candidate" ]]; then
                    local_struct_dir="$candidate"
                fi
            fi
            if [[ -z "$local_struct_dir" && -d "$local_backup_dir" ]]; then
                local_struct_dir="$local_backup_dir"
            fi

            if [[ -n "$local_struct_dir" ]] && find "$local_struct_dir" -type f -name "*.json" \
                ! -path "*/.credentials/*" \
                ! -path "*/archive/*" \
                ! -name "credentials.json" \
                ! -name "workflows.json" -print -quit >/dev/null 2>&1; then
                folder_structure_backup=true
                structured_workflows_dir="$local_struct_dir"
                log INFO "Using workflow directory from local backup: $local_struct_dir"
            else
                log WARN "No workflows.json or workflow files detected in $local_backup_dir"
            fi
        fi
    fi

    if [[ "$credentials_mode" == "1" ]]; then
        repo_credentials="$local_credentials_file"
        log INFO "Selected local credentials backup: $repo_credentials"
    fi

    # Validate files before proceeding
    log INFO "Validating files for import..."
    local file_validation_passed=true
    
    if [[ "$workflows_mode" != "0" ]]; then
        if $folder_structure_backup && [[ "$apply_folder_structure" == "true" ]]; then
            keep_api_session_alive="true"
        fi
        if $folder_structure_backup; then
            local validation_dir="$structured_workflows_dir"
            if [[ -n "$github_path" ]]; then
                validation_dir="$(resolve_github_storage_root "$validation_dir")"
            fi

            if [[ -z "$validation_dir" || ! -d "$validation_dir" ]]; then
                log ERROR "Workflow directory not found for import"
                file_validation_passed=false
                validation_dir=""
            fi

            if [[ -n "$validation_dir" ]]; then
                local separated_count
                separated_count=$(find "$validation_dir" -type f -name "*.json" \
                    ! -path "*/.credentials/*" \
                    ! -name "credentials.json" \
                    ! -name "workflows.json" \
                    -print | wc -l | tr -d ' ')
                if [[ "$separated_count" -eq 0 ]]; then
                    log ERROR "No workflow JSON files found for directory import in $validation_dir"
                    file_validation_passed=false
                else
                    log SUCCESS "Detected $separated_count workflow JSON file(s) for directory import"
                fi
            fi
        else
            if [ ! -f "$repo_workflows" ] || [ ! -s "$repo_workflows" ]; then
                log ERROR "Valid workflows.json not found for $restore_scope restore"
                file_validation_passed=false
            else
                log SUCCESS "Workflows file validated for import"
            fi
        fi
    fi
    
    if [[ "$credentials_mode" != "0" ]]; then
        if [ ! -f "$repo_credentials" ] || [ ! -s "$repo_credentials" ]; then
            log ERROR "Valid credentials.json not found for $restore_scope restore"
            log ERROR "💡 Suggestion: Try --restore-type workflows to restore workflows only"
            file_validation_passed=false
        else
            local cred_source_desc="local secure storage"
            if [[ "$repo_credentials" != "$local_credentials_file" ]]; then
                cred_source_desc="Git repository ($credentials_git_relative_dir)"
                if [[ "$repo_credentials" != *"/$credentials_subpath" ]]; then
                    cred_source_desc="Git repository (legacy layout)"
                fi
            fi
            log SUCCESS "Credentials file validated for import from $cred_source_desc"
        fi
    fi

    if [[ "$apply_folder_structure" == "auto" ]]; then
        if [[ "$workflows_mode" != "0" ]] && $folder_structure_backup && [ "$file_validation_passed" = "true" ]; then
            if [[ -n "$structured_workflows_dir" && -d "$structured_workflows_dir" ]]; then
                apply_folder_structure="true"
                log INFO "Folder structure backup detected; enabling automatic layout restoration."
            else
                apply_folder_structure="skip"
                log INFO "Workflow directory not detected; skipping folder layout restoration."
            fi
        else
            apply_folder_structure="skip"
        fi
    fi

    if [ "$file_validation_passed" != "true" ]; then
        log ERROR "File validation failed. Cannot proceed with restore."
        if [[ -n "$download_dir" ]]; then
            if rm -rf "$download_dir"; then
                log INFO "Cleaned up temporary download directory after validation failure: $download_dir"
            else
                log WARN "Unable to remove temporary download directory after validation failure: $download_dir"
            fi
        fi
        return 1
    fi
    
    # --- 2. Import Data ---
    log HEADER "Step 2: Importing Data into n8n"
    
    local pre_import_workflow_count=0
    if [[ "$workflows_mode" != "0" ]] && [ "$is_dry_run" != "true" ]; then
        local count_output=""
        if count_output=$(docker exec "$container_id" sh -c "n8n export:workflow --all --output=/tmp/pre_count.json" 2>&1); then
            if [[ -n "$count_output" ]] && echo "$count_output" | grep -qi "Error\|No workflows"; then
                local snapshot_notice="${count_output//$'\n'/ }"
                if [[ ${#snapshot_notice} -gt 300 ]]; then
                    snapshot_notice="${snapshot_notice:0:297}..."
                fi
                log DEBUG "Pre-import workflow snapshot reported: $snapshot_notice"
            else
                local pre_snapshot_tmp=""
                if pre_snapshot_tmp=$(mktemp -t n8n-pre-count-XXXXXXXX.json); then
                    if docker cp "${container_id}:/tmp/pre_count.json" "$pre_snapshot_tmp" >/dev/null 2>&1; then
                        local counted_value
                        if counted_value=$(jq -r "$WORKFLOW_COUNT_FILTER" "$pre_snapshot_tmp" 2>/dev/null); then
                            if [[ -n "$counted_value" && "$counted_value" != "null" ]]; then
                                pre_import_workflow_count="$counted_value"
                            fi
                        fi
                    fi
                    rm -f "$pre_snapshot_tmp"
                fi
            fi
        else
            if [[ -n "$count_output" ]]; then
                local snapshot_error="${count_output//$'\n'/ }"
                if [[ ${#snapshot_error} -gt 300 ]]; then
                    snapshot_error="${snapshot_error:0:297}..."
                fi
                log DEBUG "Failed to capture pre-import workflow snapshot: $snapshot_error"
            fi
        fi
        docker exec "$container_id" sh -c "rm -f /tmp/pre_count.json" 2>/dev/null || true
        log DEBUG "Pre-import workflow count: $pre_import_workflow_count"
    fi

    local container_import_workflows=""
    local workflow_import_mode="file"
    if $folder_structure_backup; then
        container_import_workflows="/tmp/n8n-workflow-import-dir-$$"
        workflow_import_mode="directory"
    else
        container_import_workflows="/tmp/import_workflows.json"
    fi
    local container_import_credentials="/tmp/import_credentials.json"

    # --- Credentials decryption integration ---
    local credentials_to_import="$repo_credentials"
    local decrypt_tmpfile=""
    local skip_credentials_restore=false
    local skip_credentials_reason=""
    if [[ "$credentials_mode" != "0" ]]; then
        # Only attempt decryption if not a dry run and file is not empty
        if [ "$is_dry_run" != "true" ] && [ -s "$repo_credentials" ]; then
            # Check if file appears to be encrypted (any credential with string data)
            if jq -e '[.[] | select(has("data") and (.data | type == "string"))] | length > 0' "$repo_credentials" >/dev/null 2>&1; then
                log INFO "Encrypted credentials detected. Preparing decryption flow..."
                local decrypt_lib="$(dirname "${BASH_SOURCE[0]}")/decrypt.sh"
                if [[ ! -f "$decrypt_lib" ]]; then
                    log ERROR "Decrypt helper not found at $decrypt_lib"
                    if [[ -n "$download_dir" ]]; then
                        rm -rf "$download_dir"
                    fi
                    return 1
                fi
                # shellcheck source=lib/decrypt.sh
                source "$decrypt_lib"
                check_dependencies

                local prompt_device="/dev/tty"
                if [[ ! -r "$prompt_device" ]]; then
                    prompt_device="/proc/self/fd/2"
                fi

                if [[ "$interactive_mode" == "true" ]]; then
                    local decrypt_success=false
                    while true; do
                        local decryption_key=""
                        printf "Enter encryption key for credentials decryption (leave blank to skip): " >"$prompt_device"
                        if ! read -r -s decryption_key <"$prompt_device"; then
                            printf '\n' >"$prompt_device" 2>/dev/null || true
                            log ERROR "Unable to read encryption key from terminal."
                            skip_credentials_restore=true
                            skip_credentials_reason="Unable to read encryption key from terminal. Skipping credential restore."
                            break
                        fi

                        printf '\n' >"$prompt_device" 2>/dev/null || echo >&2

                        if [[ -z "$decryption_key" ]]; then
                            skip_credentials_restore=true
                            skip_credentials_reason="No encryption key provided. Skipping credential restore."
                            break
                        fi

                        local attempt_tmpfile
                        attempt_tmpfile="$(mktemp -t n8n-decrypted-XXXXXXXX.json)"
                        if decrypt_credentials_file "$decryption_key" "$repo_credentials" "$attempt_tmpfile"; then
                            if ! validate_credentials_payload "$attempt_tmpfile"; then
                                log ERROR "Decrypted credentials failed validation."
                                rm -f "$attempt_tmpfile"
                            else
                                log SUCCESS "Credentials decrypted successfully."
                                decrypt_tmpfile="$attempt_tmpfile"
                                credentials_to_import="$decrypt_tmpfile"
                                decrypt_success=true
                                break
                            fi
                        else
                            log ERROR "Failed to decrypt credentials with provided key."
                            rm -f "$attempt_tmpfile"
                        fi
                    done

                    if [[ "$decrypt_success" != "true" && "$skip_credentials_restore" != "true" ]]; then
                        skip_credentials_restore=true
                        skip_credentials_reason="Decryption did not succeed. Skipping credential restore."
                    fi
                else
                    skip_credentials_restore=true
                    skip_credentials_reason="Encrypted credentials detected but running in non-interactive mode; skipping credential restore."
                fi
            fi
        fi
    fi

    if [[ "$skip_credentials_restore" == "true" ]]; then
        credentials_mode="0"
        credentials_to_import=""
        if [[ -n "$decrypt_tmpfile" ]]; then
            rm -f "$decrypt_tmpfile"
            decrypt_tmpfile=""
        fi
        if [[ -n "$skip_credentials_reason" ]]; then
            log WARN "$skip_credentials_reason"
        else
            log WARN "Credential restore will be skipped; continuing with remaining restore tasks."
        fi
    fi

    if [[ "$credentials_mode" != "0" ]] && [ "$is_dry_run" != "true" ]; then
        if ! validate_credentials_payload "$credentials_to_import"; then
            if [[ -n "$decrypt_tmpfile" ]]; then
                rm -f "$decrypt_tmpfile"
            fi
            if [[ -n "$download_dir" ]]; then
                rm -rf "$download_dir"
            fi
            return 1
        fi
    fi

    log INFO "Copying files to container..."
    local copy_status="success"
    local existing_workflow_snapshot=""
    local existing_workflow_mapping=""
    existing_workflow_snapshot_source=""

    # Copy workflow file if needed
    if [[ "$workflows_mode" != "0" ]]; then
        if $folder_structure_backup; then
            local stage_source_dir="$structured_workflows_dir"
            if [[ -n "$github_path" ]]; then
                stage_source_dir="$(resolve_github_storage_root "$stage_source_dir")"
            fi

            if [[ "$is_dry_run" == "true" ]]; then
                resolved_structured_dir="$stage_source_dir"
                if [[ -z "$stage_source_dir" || ! -d "$stage_source_dir" ]]; then
                    log DRYRUN "Would skip staging workflows because source directory is unavailable (${stage_source_dir:-<empty>})"
                else
                    log DRYRUN "Would stage workflows in ${container_import_workflows} by scanning directory $stage_source_dir"
                fi
            else
                if [[ -z "$stage_source_dir" || ! -d "$stage_source_dir" ]]; then
                    log ERROR "Workflow directory not found for staging: ${stage_source_dir:-<empty>}"
                    copy_status="failed"
                elif ! dockExec "$container_id" "rm -rf $container_import_workflows && mkdir -p $container_import_workflows" false; then
                    log ERROR "Failed to prepare container directory for workflow import."
                    copy_status="failed"
                else
                    if [[ "$is_dry_run" != "true" && -z "$existing_workflow_snapshot" ]]; then
                        SNAPSHOT_EXISTING_WORKFLOWS_PATH=""
                        if snapshot_existing_workflows "$container_id" "" "$keep_api_session_alive"; then
                            existing_workflow_snapshot="$SNAPSHOT_EXISTING_WORKFLOWS_PATH"
                            log DEBUG "Captured existing workflow snapshot from ${existing_workflow_snapshot_source:-unknown} source for duplicate detection."
                        fi
                    fi

                    if [[ -z "$existing_workflow_mapping" && "$is_dry_run" != "true" ]]; then
                        if [[ -n "$n8n_base_url" ]]; then
                            local mapping_json
                            if mapping_json=$(get_workflow_folder_mapping "$container_id"); then
                                existing_workflow_mapping=$(mktemp -t n8n-workflow-map-XXXXXXXX.json)
                                printf '%s' "$mapping_json" > "$existing_workflow_mapping"
                                log DEBUG "Captured workflow folder mapping for scoped duplicate detection."
                            else
                                log WARN "Unable to retrieve workflow folder mapping; duplicate matching will fall back to snapshot data."
                            fi
                        else
                            log DEBUG "Skipping workflow mapping fetch; n8n base URL not configured."
                        fi
                    fi

                    staged_manifest_file=$(mktemp -t n8n-staged-workflows-XXXXXXXX.json)
                    if ! stage_directory_workflows_to_container "$stage_source_dir" "$container_id" "$container_import_workflows" "$staged_manifest_file" "$existing_workflow_snapshot" "$preserve_ids" "$no_overwrite" "$existing_workflow_mapping"; then
                        rm -f "$staged_manifest_file"
                        log ERROR "Failed to copy workflow files into container."
                        copy_status="failed"
                    else
                        resolved_structured_dir="$stage_source_dir"
                        log SUCCESS "Workflow files prepared in container directory $container_import_workflows"
                    fi
                fi
            fi
        else
            if [ "$is_dry_run" = "true" ]; then
                log DRYRUN "Would copy $repo_workflows to ${container_id}:${container_import_workflows}"
            else
                if docker cp "$repo_workflows" "${container_id}:${container_import_workflows}"; then
                    log SUCCESS "Successfully copied workflows.json to container"
                else
                    log ERROR "Failed to copy workflows.json to container."
                    copy_status="failed"
                fi
            fi
        fi

        if [[ "$copy_status" == "success" ]]; then
            if [[ -z "$existing_workflow_snapshot" && "$is_dry_run" != "true" ]]; then
                SNAPSHOT_EXISTING_WORKFLOWS_PATH=""
                if snapshot_existing_workflows "$container_id" "" "$keep_api_session_alive"; then
                    existing_workflow_snapshot="$SNAPSHOT_EXISTING_WORKFLOWS_PATH"
                    log DEBUG "Captured existing workflow snapshot from ${existing_workflow_snapshot_source:-unknown} source for duplicate detection."
                fi
            fi

            # Preserve staged manifest for in-place updates during reconciliation
            if [[ -n "$staged_manifest_file" && -f "$staged_manifest_file" ]]; then
                if [[ -n "${RESTORE_MANIFEST_STAGE_DEBUG_PATH:-}" ]]; then
                    if ! cp "$staged_manifest_file" "${RESTORE_MANIFEST_STAGE_DEBUG_PATH}" 2>/dev/null; then
                        log DEBUG "Unable to persist staged manifest to ${RESTORE_MANIFEST_STAGE_DEBUG_PATH}"
                    else
                        log DEBUG "Persisted staged manifest to ${RESTORE_MANIFEST_STAGE_DEBUG_PATH}"
                    fi
                fi
                # Keep staged_manifest_file for in-place reconciliation (no copy needed)
            fi
        fi
    fi

    # Copy credentials file if needed (use decrypted if available)
    if [[ "$credentials_mode" != "0" ]]; then
        if [ "$is_dry_run" = "true" ]; then
            log DRYRUN "Would copy $credentials_to_import to ${container_id}:${container_import_credentials}"
        else
            if docker cp "$credentials_to_import" "${container_id}:${container_import_credentials}"; then
                log SUCCESS "Successfully copied credentials.json to container"
            else
                log ERROR "Failed to copy credentials.json to container."
                copy_status="failed"
            fi
        fi
    fi

    # Clean up decrypted temp file if used
    if [ -n "$decrypt_tmpfile" ]; then
        rm -f "$decrypt_tmpfile"
    fi
    
    if [ "$copy_status" = "failed" ]; then
        log ERROR "Failed to copy files to container - cannot proceed with restore"
        if [[ -n "$download_dir" ]]; then
            rm -rf "$download_dir"
        fi
        return 1
    fi

    if [ "$is_dry_run" != "true" ]; then
        if [[ "$workflows_mode" != "0" ]]; then
            dockExecAsRoot "$container_id" "if [ -d '$container_import_workflows' ]; then chown -R node:node '$container_import_workflows'; fi" false || log WARN "Unable to adjust ownership for workflow import directory"
        fi
        if [[ "$credentials_mode" != "0" ]]; then
            dockExecAsRoot "$container_id" "if [ -e '$container_import_credentials' ]; then chown -R node:node '$container_import_credentials'; fi" false || log WARN "Unable to adjust ownership for credentials import file"
        fi
    fi
    
    # Import data
    log INFO "Importing data into n8n..."
    local import_status="success"
    
    # Import workflows if needed
    if [[ "$workflows_mode" != "0" ]]; then
        if [ "$is_dry_run" = "true" ]; then
            if [[ "$workflow_import_mode" == "directory" ]]; then
                log DRYRUN "Would enumerate workflow JSON files under $container_import_workflows and import each individually"
            else
                log DRYRUN "Would run: n8n import:workflow --input=$container_import_workflows"
            fi
        else
            log INFO "Importing workflows..."
            if [[ "$workflow_import_mode" == "directory" ]]; then
                local -a container_workflow_files=()
                if ! mapfile -t container_workflow_files < <(docker exec "$container_id" sh -c "find '$container_import_workflows' -type f -name '*.json' -print 2>/dev/null | sort" ); then
                    log ERROR "Unable to enumerate staged workflows in $container_import_workflows"
                    import_status="failed"
                elif ((${#container_workflow_files[@]} == 0)); then
                    log ERROR "No workflow JSON files found in $container_import_workflows to import"
                    import_status="failed"
                else
                    local imported_count=0
                    local failed_count=0
                    for workflow_file in "${container_workflow_files[@]}"; do
                        if [[ -z "$workflow_file" ]]; then
                            continue
                        fi
                        log INFO "Importing workflow file: $workflow_file"
                        local escaped_file
                        escaped_file=$(printf '%q' "$workflow_file")
                        if ! dockExec "$container_id" "n8n import:workflow --input=$escaped_file" false; then
                            log ERROR "Failed to import workflow file: $workflow_file"
                            failed_count=$((failed_count + 1))
                        else
                            imported_count=$((imported_count + 1))
                        fi
                    done

                    if (( failed_count > 0 )); then
                        log ERROR "Failed to import $failed_count workflow file(s) from $container_import_workflows"
                        import_status="failed"
                    else
                        log SUCCESS "Imported $imported_count workflow file(s)"
                        
                        # CRITICAL: Capture post-import snapshot to identify newly created workflow IDs
                        # This handles cases where n8n rejects invalid IDs (like '47') and creates new ones
                        if [[ -n "$existing_workflow_snapshot" && -f "$existing_workflow_snapshot" && -n "$staged_manifest_file" && -f "$staged_manifest_file" ]]; then
                            local post_import_snapshot=""
                            SNAPSHOT_EXISTING_WORKFLOWS_PATH=""
                            if snapshot_existing_workflows "$container_id" "" "$keep_api_session_alive"; then
                                post_import_snapshot="$SNAPSHOT_EXISTING_WORKFLOWS_PATH"
                                log DEBUG "Captured post-import workflow snapshot for ID reconciliation"
                                
                                # Update manifest with actual imported workflow IDs by comparing snapshots
                                # The reconcile function now exports metrics directly
                                local updated_manifest
                                updated_manifest=$(mktemp -t n8n-updated-manifest-XXXXXXXX.ndjson)
                                if reconcile_imported_workflow_ids "$existing_workflow_snapshot" "$post_import_snapshot" "$staged_manifest_file" "$updated_manifest"; then
                                    mv "$updated_manifest" "$staged_manifest_file"
                                    log INFO "Reconciled manifest with actual imported workflow IDs from n8n"
                                    summarize_manifest_assignment_status "$staged_manifest_file" "post-import"
                                    
                                    # Metrics already exported by reconcile_imported_workflow_ids:
                                    # - RESTORE_WORKFLOWS_CREATED
                                    # - RESTORE_WORKFLOWS_UPDATED
                                    # - RESTORE_POST_IMPORT_COUNT
                                else
                                    rm -f "$updated_manifest"
                                    log WARN "Unable to reconcile workflow IDs from post-import snapshot; folder assignment may be affected"
                                fi
                                
                                rm -f "$post_import_snapshot"
                            else
                                log WARN "Failed to capture post-import snapshot; workflow ID reconciliation skipped"
                            fi
                        fi
                    fi
                fi
            else
                if ! dockExec "$container_id" "n8n import:workflow --input=$container_import_workflows" "$is_dry_run"; then
                    log WARN "Standard import failed, trying with --separate flag..."
                    if ! dockExec "$container_id" "n8n import:workflow --separate --input=$container_import_workflows" "$is_dry_run"; then
                        log ERROR "Failed to import workflows"
                        import_status="failed"
                    else
                        log SUCCESS "Workflows imported successfully with --separate flag"
                    fi
                else
                    log SUCCESS "Workflows imported successfully"
                fi
            fi
        fi
    fi
    
    # Import credentials if needed
    if [[ "$credentials_mode" != "0" ]]; then
        if [ "$is_dry_run" = "true" ]; then
            log DRYRUN "Would run: n8n import:credentials --input=$container_import_credentials"
        else
            log INFO "Importing credentials..."
            if ! dockExec "$container_id" "n8n import:credentials --input=$container_import_credentials" "$is_dry_run"; then
                # Try with --separate flag on failure
                log WARN "Standard import failed, trying with --separate flag..."
                if ! dockExec "$container_id" "n8n import:credentials --separate --input=$container_import_credentials" "$is_dry_run"; then
                    log ERROR "Failed to import credentials"
                    import_status="failed"
                else
                    log SUCCESS "Credentials imported successfully with --separate flag"
                fi
            else
                log SUCCESS "Credentials imported successfully"
            fi
        fi
    fi
    
    if [[ "$workflows_mode" != "0" ]] && $folder_structure_backup && [ "$import_status" != "failed" ] && [[ "$apply_folder_structure" == "true" ]]; then
        local folder_source_dir="$resolved_structured_dir"
        if [[ -z "$folder_source_dir" ]]; then
            folder_source_dir="$structured_workflows_dir"
            if [[ -n "$github_path" ]]; then
                folder_source_dir="$(resolve_github_storage_root "$folder_source_dir")"
            fi
        fi

        if [[ -z "$folder_source_dir" || ! -d "$folder_source_dir" ]]; then
            if [[ "$is_dry_run" == "true" ]]; then
                log DRYRUN "Would apply folder structure from directory, but source is unavailable (${folder_source_dir:-<empty>})."
            else
                log WARN "Workflow directory unavailable for folder restoration; skipping folder assignment."
            fi
        else
            if ! apply_folder_structure_from_directory "$folder_source_dir" "$container_id" "$is_dry_run" "" "$staged_manifest_file"; then
                log WARN "Folder structure restoration encountered issues; workflows may require manual reorganization."
            fi
        fi
    fi

    # Clean up manifest and snapshot files
    if [[ -n "$staged_manifest_file" && -f "$staged_manifest_file" ]]; then
        if [[ -n "${RESTORE_MANIFEST_DEBUG_PATH:-}" ]]; then
            if ! cp "$staged_manifest_file" "${RESTORE_MANIFEST_DEBUG_PATH}" 2>/dev/null; then
                log DEBUG "Unable to persist restore manifest to ${RESTORE_MANIFEST_DEBUG_PATH}"
            else
                log DEBUG "Persisted restore manifest to ${RESTORE_MANIFEST_DEBUG_PATH}"
            fi
        fi
        rm -f "$staged_manifest_file"
    fi
    if [[ -n "$existing_workflow_snapshot" && -f "$existing_workflow_snapshot" ]]; then
        rm -f "$existing_workflow_snapshot"
    fi
    if [[ -n "$existing_workflow_mapping" && -f "$existing_workflow_mapping" ]]; then
        rm -f "$existing_workflow_mapping"
    fi

    # Clean up temporary files in container
    if [ "$is_dry_run" != "true" ]; then
        log DEBUG "Cleaning up temporary files in container..."
        dockExecAsRoot "$container_id" "rm -rf $container_import_workflows $container_import_credentials 2>/dev/null || true" false >/dev/null 2>&1
    fi
    
    # Clean up downloaded repository
    if [[ -n "$download_dir" ]]; then
        rm -rf "$download_dir" 2>/dev/null || true
    fi

    # Clean up n8n API session BEFORE the summary
    if [[ "$keep_api_session_alive" == "true" && -n "${N8N_API_AUTH_MODE:-}" ]]; then
        finalize_n8n_api_auth
        keep_api_session_alive="false"
    fi
    
    # Clean up session cookie file explicitly (prevents EXIT trap message)
    if [[ -n "${N8N_SESSION_COOKIE_FILE:-}" && -f "${N8N_SESSION_COOKIE_FILE}" ]]; then
        rm -f "$N8N_SESSION_COOKIE_FILE" 2>/dev/null || true
        log DEBUG "Cleaned up session cookie file"
        N8N_SESSION_COOKIE_FILE=""
    fi
    
    # Handle restore result
    if [ "$import_status" = "failed" ]; then
        log WARN "Restore partially completed with some errors. Check logs for details."
        return 1
    fi
    
    # ============================================================================
    # RESTORE SUMMARY - Collect all metrics and display in comprehensive format
    # ============================================================================
    
    log HEADER "Restore Summary"
    
    # Collect workflow metrics from exported environment variables (no queries needed)
    local post_import_workflow_count=${RESTORE_POST_IMPORT_COUNT:-0}
    local pre_import_count=${pre_import_workflow_count:-0}
    local created_count=${RESTORE_WORKFLOWS_CREATED:-0}
    local updated_count=${RESTORE_WORKFLOWS_UPDATED:-0}
    local staged_count=${RESTORE_WORKFLOWS_TOTAL:-0}
    local had_workflow_activity=false
    
    # Determine if workflow activity occurred
    if [[ $staged_count -gt 0 ]] || [[ $created_count -gt 0 ]] || [[ $updated_count -gt 0 ]]; then
        had_workflow_activity=true
    fi
    
    # Collect folder structure metrics from exported environment variables
    local projects_created=${RESTORE_PROJECTS_CREATED:-0}
    local folders_created=${RESTORE_FOLDERS_CREATED:-0}
    local folders_moved=${RESTORE_FOLDERS_MOVED:-0}
    local workflows_repositioned=${RESTORE_WORKFLOWS_REASSIGNED:-0}
    local folder_sync_ran=${RESTORE_FOLDER_SYNC_RAN:-false}
    
    # Display summary table
    if [[ "$workflows_mode" != "0" || "$credentials_mode" != "0" ]]; then
        echo ""
        echo "╔════════════════════════════════════════════════════════════════╗"
        echo "║                      RESTORE RESULTS                           ║"
        echo "╠════════════════════════════════════════════════════════════════╣"
        
        if [[ "$workflows_mode" != "0" ]]; then
            echo "║  Workflows:                                                    ║"
            if [[ $had_workflow_activity == true ]]; then
                printf "║    • Workflows created:     %-35s║\n" "$created_count"
                printf "║    • Workflows updated:     %-35s║\n" "$updated_count"
                printf "║    • Total in instance:     %-35s║\n" "$post_import_workflow_count"
            else
                printf "║    • No changes (already up to date)                           ║\n"
                printf "║    • Total in instance:     %-35s║\n" "$post_import_workflow_count"
            fi
            
            if [[ "$folder_sync_ran" == "true" ]]; then
                echo "║                                                                ║"
                echo "║  Folder Organization:                                          ║"
                if [[ $projects_created -gt 0 || $folders_created -gt 0 || $folders_moved -gt 0 || $workflows_repositioned -gt 0 ]]; then
                    printf "║    • Projects created:      %-35s║\n" "$projects_created"
                    printf "║    • Folders created:       %-35s║\n" "$folders_created"
                    printf "║    • Folders repositioned:  %-35s║\n" "$folders_moved"
                    printf "║    • Workflows repositioned: %-34s║\n" "$workflows_repositioned"
                else
                    printf "║    • All workflows already in target folders                   ║\n"
                fi
            fi
        fi
        
        if [[ "$credentials_mode" != "0" ]]; then
            echo "║                                                                ║"
            echo "║  Credentials:                                                  ║"
            printf "║    • Imported successfully                                     ║\n"
        fi
        
        echo "╚════════════════════════════════════════════════════════════════╝"
        echo ""
    fi
    
    # Final status message
    if [[ $had_workflow_activity == true ]] || [[ $workflows_repositioned -gt 0 ]] || [[ "$credentials_mode" != "0" ]]; then
        log SUCCESS "✅ Restore completed successfully!"
    else
        log INFO "Restore completed with no changes (all content already up to date)."
    fi
    
    return 0
}