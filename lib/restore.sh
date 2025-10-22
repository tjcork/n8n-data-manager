#!/usr/bin/env bash
# =========================================================
# lib/restore.sh - Restore operations for n8n-manager
# =========================================================
# All restore-related functions: restore process, rollback

# Source required modules
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/n8n-api.sh"
source "$(dirname "${BASH_SOURCE[0]}")/restore/utils.sh"
source "$(dirname "${BASH_SOURCE[0]}")/restore/staging.sh"
source "$(dirname "${BASH_SOURCE[0]}")/restore/folder_state.sh"
source "$(dirname "${BASH_SOURCE[0]}")/restore/folder_sync.sh"
source "$(dirname "${BASH_SOURCE[0]}")/restore/folder_assignment.sh"
source "$(dirname "${BASH_SOURCE[0]}")/restore/validate.sh"

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
    preserve_ids="$(normalize_boolean_option "$preserve_ids")"
    local preserve_ids_requested="$preserve_ids"

    invalidate_n8n_state_cache

    no_overwrite="$(normalize_boolean_option "$no_overwrite")"
    if [[ "$no_overwrite" == "true" ]]; then
        preserve_ids="false"
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
            cleanup_temp_path "$download_dir"
            return 1
        fi

        selected_base_dir="$download_dir"

        cd "$download_dir" || {
            log ERROR "Failed to change to download directory"
            cleanup_temp_path "$download_dir"
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
            locate_workflow_artifacts "$selected_base_dir" "$download_dir" "$project_storage_relative" repo_workflows structured_workflows_dir

            if [[ -n "$structured_workflows_dir" ]]; then
                folder_structure_backup=true
                log INFO "Detected workflow directory: $structured_workflows_dir"
            elif [[ -n "$repo_workflows" ]]; then
                log SUCCESS "Found workflows.json in remote backup: $repo_workflows"
            else
                log DEBUG "No workflow directory or workflows.json found in remote backup scope."
            fi
        fi

        if [[ "$credentials_mode" == "2" ]]; then
            locate_credentials_artifact "$selected_base_dir" "$download_dir" "$credentials_subpath" repo_credentials
            if [[ -n "$repo_credentials" ]]; then
                log SUCCESS "Found credentials file: $repo_credentials"
            fi
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
        local detected_local_workflows=""
        local detected_local_directory=""
        locate_workflow_artifacts "$local_backup_dir" "$local_backup_dir" "$project_storage_relative" detected_local_workflows detected_local_directory

        if [[ -n "$detected_local_directory" ]]; then
            folder_structure_backup=true
            structured_workflows_dir="$detected_local_directory"
            log INFO "Using workflow directory from local backup: $structured_workflows_dir"
        fi

        if [[ -z "$repo_workflows" && -n "$detected_local_workflows" ]]; then
            repo_workflows="$detected_local_workflows"
            log INFO "Selected local workflows backup: $repo_workflows"
        fi

        if [[ -z "$repo_workflows" && -z "$structured_workflows_dir" ]]; then
            log WARN "No workflows.json or workflow files detected in $local_backup_dir"
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
            if cleanup_temp_path "$download_dir"; then
                log INFO "Cleaned up temporary download directory after validation failure: $download_dir"
            else
                log WARN "Unable to remove temporary download directory after validation failure: $download_dir"
            fi
        fi
        return 1
    fi
    
    # --- 2. Import Data ---
    log HEADER "Step 2: Importing Data into n8n"

    local existing_workflow_snapshot=""
    local existing_workflow_mapping=""
    existing_workflow_snapshot_source=""

    local pre_import_workflow_count=0
    if [[ "$workflows_mode" != "0" ]] && [ "$is_dry_run" != "true" ]; then
        if ! capture_existing_workflow_snapshot "$container_id" "$keep_api_session_alive" "$existing_workflow_snapshot" "$is_dry_run" existing_workflow_snapshot; then
            existing_workflow_snapshot=""
        fi
        if [[ -n "$existing_workflow_snapshot" && -f "$existing_workflow_snapshot" ]]; then
            local counted_value
            if counted_value=$(jq -r "$WORKFLOW_COUNT_FILTER" "$existing_workflow_snapshot" 2>/dev/null); then
                if [[ -n "$counted_value" && "$counted_value" != "null" ]]; then
                    pre_import_workflow_count="$counted_value"
                fi
            fi
            if [[ "$verbose" == "true" ]]; then
                log DEBUG "Pre-import workflow snapshot captured via ${existing_workflow_snapshot_source:-unknown} source"
            fi
        else
            log DEBUG "Pre-import workflow snapshot unavailable; assuming 0 existing workflows"
        fi
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
                        cleanup_temp_path "$download_dir"
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
                cleanup_temp_path "$download_dir"
            fi
            return 1
        fi
    fi

    log INFO "Copying files to container..."
    local copy_status="success"

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
                    if [[ "$is_dry_run" != "true" ]]; then
                        if ! capture_existing_workflow_snapshot "$container_id" "$keep_api_session_alive" "$existing_workflow_snapshot" "$is_dry_run" existing_workflow_snapshot; then
                            existing_workflow_snapshot=""
                        fi
                        if [[ -n "$existing_workflow_snapshot" ]]; then
                            log DEBUG "Captured existing workflow snapshot from ${existing_workflow_snapshot_source:-unknown} source for duplicate detection."
                        fi
                    fi

                    if [[ -z "$existing_workflow_mapping" && "$is_dry_run" != "true" ]]; then
                        if [[ -n "$n8n_base_url" ]]; then
                            local mapping_json=""
                            if get_workflow_folder_mapping "$container_id" "" mapping_json; then
                                existing_workflow_mapping=$(mktemp -t n8n-workflow-map-XXXXXXXX.json)
                                printf '%s' "$mapping_json" > "$existing_workflow_mapping"
                                log DEBUG "Captured workflow folder mapping for duplicate detection."
                            else
                                log WARN "Unable to retrieve workflow folder mapping; duplicate matching will fall back to snapshot data."
                            fi
                        else
                            log DEBUG "Skipping workflow mapping fetch; n8n base URL not configured."
                        fi
                    fi

                    staged_manifest_file=$(mktemp -t n8n-staged-workflows-XXXXXXXX.json)
                    if ! stage_directory_workflows_to_container "$stage_source_dir" "$container_id" "$container_import_workflows" "$staged_manifest_file" "$existing_workflow_snapshot" "$preserve_ids" "$no_overwrite" "$existing_workflow_mapping" "$n8n_path"; then
                        rm -f "$staged_manifest_file"
                        log ERROR "Failed to copy workflow files into container."
                        copy_status="failed"
                    else
                        resolved_structured_dir="$stage_source_dir"
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
            if [[ "$is_dry_run" != "true" ]]; then
                if ! capture_existing_workflow_snapshot "$container_id" "$keep_api_session_alive" "$existing_workflow_snapshot" "$is_dry_run" existing_workflow_snapshot; then
                    existing_workflow_snapshot=""
                fi
                if [[ -n "$existing_workflow_snapshot" ]]; then
                    log DEBUG "Captured pre-import workflows snapshot for post-import ID detection."
                fi

                # Preserve staged manifest for in-place updates during reconciliation
                if [[ -n "$staged_manifest_file" && -f "$staged_manifest_file" ]]; then
                    persist_manifest_debug_copy "$staged_manifest_file" "${RESTORE_MANIFEST_STAGE_DEBUG_PATH:-}" "staged manifest"
                    # Keep staged_manifest_file for in-place reconciliation (no copy needed)
                fi
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
            cleanup_temp_path "$download_dir"
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
                        
                        # Capture post-import snapshot to identify newly created workflow IDs
                        if [[ -n "$existing_workflow_snapshot" && -f "$existing_workflow_snapshot" && -n "$staged_manifest_file" && -f "$staged_manifest_file" ]]; then
                            local post_import_snapshot=""
                            SNAPSHOT_EXISTING_WORKFLOWS_PATH=""
                            if snapshot_existing_workflows "$container_id" "" "$keep_api_session_alive"; then
                                post_import_snapshot="$SNAPSHOT_EXISTING_WORKFLOWS_PATH"
                                log DEBUG "Captured post-import workflow snapshot for ID reconciliation"
                                
                                # Update manifest with actual imported workflow IDs by comparing snapshots
                                local updated_manifest
                                updated_manifest=$(mktemp -t n8n-updated-manifest-XXXXXXXX.ndjson)
                                if reconcile_imported_workflow_ids "$existing_workflow_snapshot" "$post_import_snapshot" "$staged_manifest_file" "$updated_manifest"; then
                                    mv "$updated_manifest" "$staged_manifest_file"
                                    log INFO "Reconciled manifest with actual imported workflow IDs from n8n"
                                    summarize_manifest_assignment_status "$staged_manifest_file" "post-import"
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
            if ! apply_folder_structure_from_directory "$folder_source_dir" "$container_id" "$is_dry_run" "" "$staged_manifest_file" "$n8n_path" true; then
                log WARN "Folder structure restoration encountered issues; workflows may require manual reorganization."
            fi
        fi
    fi

    # Clean up manifest and snapshot files
    if [[ -n "$staged_manifest_file" && -f "$staged_manifest_file" ]]; then
        persist_manifest_debug_copy "$staged_manifest_file" "${RESTORE_MANIFEST_DEBUG_PATH:-}" "restore manifest"
        cleanup_temp_path "$staged_manifest_file"
    fi
    if [[ -n "$existing_workflow_snapshot" && -f "$existing_workflow_snapshot" ]]; then
        cleanup_temp_path "$existing_workflow_snapshot"
    fi
    if [[ -n "$existing_workflow_mapping" && -f "$existing_workflow_mapping" ]]; then
        cleanup_temp_path "$existing_workflow_mapping"
    fi

    # Clean up temporary files in container
    if [ "$is_dry_run" != "true" ]; then
        log DEBUG "Cleaning up temporary files in container..."
        dockExecAsRoot "$container_id" "rm -rf $container_import_workflows $container_import_credentials 2>/dev/null || true" false >/dev/null 2>&1
    fi
    
    # Clean up downloaded repository
    if [[ -n "$download_dir" ]]; then
        cleanup_temp_path "$download_dir"
    fi

    # DO NOT clean up session yet - needed for folder structure sync and summary queries
    
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
        :  # no-op: success message handled on return
    else
        log INFO "Restore completed with no changes (all content already up to date)."
    fi
    
    # NOW clean up n8n API session AFTER all operations complete
    if [[ "$keep_api_session_alive" == "true" && -n "${N8N_API_AUTH_MODE:-}" ]]; then
        finalize_n8n_api_auth
        keep_api_session_alive="false"
    fi
    
    # Clean up session cookie file explicitly (prevents EXIT trap message)
    if [[ -n "${N8N_SESSION_COOKIE_FILE:-}" && -f "${N8N_SESSION_COOKIE_FILE}" ]]; then
        rm -f "$N8N_SESSION_COOKIE_FILE" 2>/dev/null || true
        log DEBUG "Cleaned up session cookie file"
        N8N_SESSION_COOKIE_FILE=""
        N8N_SESSION_COOKIE_INITIALIZED="false"
        N8N_SESSION_COOKIE_READY="false"
    fi
    
    return 0
}