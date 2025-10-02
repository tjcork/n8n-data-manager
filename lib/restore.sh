#!/usr/bin/env bash
# =========================================================
# lib/restore.sh - Restore operations for n8n-manager
# =========================================================
# All restore-related functions: restore process, rollback

# Source required modules
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

apply_folder_structure_from_manifest() {
    local manifest_path="$1"
    local container_id="$2"
    local is_dry_run="$3"
    local container_credentials_path="$4"

    if $is_dry_run; then
        log DRYRUN "Would apply folder structure using manifest: $manifest_path"
        return 0
    fi

    if [[ ! -f "$manifest_path" ]]; then
        log WARN "Folder structure manifest not found: $manifest_path"
        return 0
    fi

    if [[ -z "${n8n_base_url:-}" ]]; then
        log WARN "n8n base URL not configured; skipping folder structure restoration."
        return 0
    fi

    if [[ -z "${n8n_api_key:-}" && -z "${n8n_session_credential:-}" ]]; then
        log WARN "No n8n API authentication configured; skipping folder structure restoration."
        return 0
    fi

    if ! prepare_n8n_api_auth "$container_id" "$container_credentials_path"; then
        log WARN "Unable to authenticate with n8n API; skipping folder structure restoration."
        return 0
    fi

    local projects_json
    if ! projects_json=$(n8n_api_get_projects); then
        finalize_n8n_api_auth
        log ERROR "Failed to fetch projects from n8n API."
        return 1
    fi

    local folders_json
    if ! folders_json=$(n8n_api_get_folders); then
        finalize_n8n_api_auth
        log ERROR "Failed to fetch folders from n8n API."
        return 1
    fi

    declare -A project_name_map=()
    declare -A project_id_map=()
    local default_project_id=""

    while IFS= read -r project_entry; do
        local pid
        pid=$(printf '%s' "$project_entry" | jq -r '.id // empty' 2>/dev/null)
        local pname
        pname=$(printf '%s' "$project_entry" | jq -r '.name // empty' 2>/dev/null)
        if [[ -z "$pid" ]]; then
            continue
        fi
        local key
        key=$(printf '%s' "$pname" | tr '[:upper:]' '[:lower:]')
        project_name_map["$key"]="$pid"
        project_id_map["$pid"]="$pname"
        if [[ -z "$default_project_id" ]]; then
            default_project_id="$pid"
        fi
    done < <(printf '%s' "$projects_json" | jq -c 'if type == "array" then .[] else (.data // [])[] end')

    if [[ -z "$default_project_id" ]]; then
        finalize_n8n_api_auth
        log ERROR "No projects available in n8n instance; cannot restore folder structure."
        return 1
    fi

    declare -A folder_lookup=()
    while IFS= read -r folder_entry; do
        local fid
        fid=$(printf '%s' "$folder_entry" | jq -r '.id // empty' 2>/dev/null)
        local fname
        fname=$(printf '%s' "$folder_entry" | jq -r '.name // empty' 2>/dev/null)
        local fproject
        fproject=$(printf '%s' "$folder_entry" | jq -r '.projectId // empty' 2>/dev/null)
        if [[ -z "$fid" || -z "$fproject" ]]; then
            continue
        fi
        local parent
        parent=$(printf '%s' "$folder_entry" | jq -r '.parentFolderId // empty' 2>/dev/null)
        local parent_key="${parent:-root}"
        local lookup_key="$fproject|$parent_key|$(printf '%s' "$fname" | tr '[:upper:]' '[:lower:]')"
        folder_lookup["$lookup_key"]="$fid"
    done < <(printf '%s' "$folders_json" | jq -c 'if type == "array" then .[] else (.data // [])[] end')

    local total_count
    total_count=$(jq -r '.workflows | length' "$manifest_path" 2>/dev/null || echo 0)
    if [[ "$total_count" -eq 0 ]]; then
        finalize_n8n_api_auth
        log INFO "Folder structure manifest empty; nothing to apply."
        return 0
    fi

    local moved_count=0
    local overall_success=true

    while IFS= read -r entry; do
        local workflow_id
        workflow_id=$(printf '%s' "$entry" | jq -r '.id // empty' 2>/dev/null)
        local workflow_name
        workflow_name=$(printf '%s' "$entry" | jq -r '.name // "Workflow"' 2>/dev/null)
        local display_path
        display_path=$(printf '%s' "$entry" | jq -r '.displayPath // empty' 2>/dev/null)

        local project_name
        project_name=$(printf '%s' "$entry" | jq -r '.project.name // empty' 2>/dev/null)
        local project_id_manifest
        project_id_manifest=$(printf '%s' "$entry" | jq -r '.project.id // empty' 2>/dev/null)

        local target_project_id=""
        if [[ -n "$project_id_manifest" && -n "${project_id_map[$project_id_manifest]+set}" ]]; then
            target_project_id="$project_id_manifest"
        elif [[ -n "$project_name" ]]; then
            local project_key
            project_key=$(printf '%s' "$project_name" | tr '[:upper:]' '[:lower:]')
            if [[ -n "${project_name_map[$project_key]+set}" ]]; then
                target_project_id="${project_name_map[$project_key]}"
            fi
        fi

        if [[ -z "$target_project_id" ]]; then
            target_project_id="$default_project_id"
            if [[ -n "$project_name" ]]; then
                log WARN "Project '$project_name' not found; assigning workflow '$workflow_name' to default project."
            fi
        fi

        local folder_names=()
        while IFS= read -r folder_name; do
            if [[ -n "$folder_name" ]]; then
                folder_names+=("$folder_name")
            fi
        done < <(printf '%s' "$entry" | jq -r '.folders[].name // empty' 2>/dev/null)

        local parent_folder_id=""
        local folder_failure=false

        for folder_name in "${folder_names[@]}"; do
            local parent_key="${parent_folder_id:-root}"
            local lookup_key="$target_project_id|$parent_key|$(printf '%s' "$folder_name" | tr '[:upper:]' '[:lower:]')"
            local existing_folder_id="${folder_lookup[$lookup_key]:-}"

            if [[ -z "$existing_folder_id" ]]; then
                local create_response
                if ! create_response=$(n8n_api_create_folder "$folder_name" "$target_project_id" "$parent_folder_id"); then
                    log ERROR "Failed to create folder '$folder_name' in project '${project_id_map[$target_project_id]:-Default}'"
                    folder_failure=true
                    break
                fi
                existing_folder_id=$(printf '%s' "$create_response" | jq -r '.id // empty' 2>/dev/null)
                if [[ -z "$existing_folder_id" ]]; then
                    log ERROR "n8n API did not return an ID when creating folder '$folder_name'"
                    folder_failure=true
                    break
                fi
                folder_lookup["$lookup_key"]="$existing_folder_id"
                log INFO "Created n8n folder '$folder_name' in project '${project_id_map[$target_project_id]:-Default}'"
            fi

            parent_folder_id="$existing_folder_id"
        done

        if $folder_failure; then
            overall_success=false
            continue
        fi

        local assignment_folder_id="${parent_folder_id:-}"
        if ! n8n_api_update_workflow_assignment "$workflow_id" "$target_project_id" "$assignment_folder_id"; then
            log WARN "Failed to assign workflow '$workflow_name' ($workflow_id) to target folder structure."
            overall_success=false
            continue
        fi

        moved_count=$((moved_count + 1))
    done < <(jq -c '.workflows[]' "$manifest_path" 2>/dev/null)

    finalize_n8n_api_auth

    if ! $overall_success; then
        log WARN "Folder structure restoration completed with warnings ($moved_count/$total_count workflows updated)."
        return 1
    fi

    log SUCCESS "Folder structure restored for $moved_count workflow(s)."
    return 0
}

restore() {
    local container_id="$1"
    local github_token="$2"
    local github_repo="$3"
    local branch="$4"
    local workflows_mode="${5:-2}"
    local credentials_mode="${6:-1}"
    local apply_folder_structure="${7:-false}"
    local is_dry_run=${8:-false}
    local credentials_folder_name="${9:-.credentials}"
    local folder_structure_backup=false
    local folder_manifest_path=""
    local folder_manifest_base=""
    local download_dir=""
    local repo_workflows=""
    local repo_credentials=""
    local selected_base_dir=""
    local selected_backup=""
    local dated_backup_found=false

    local local_backup_dir="$HOME/n8n-backup"
    local local_workflows_file="$local_backup_dir/workflows.json"
    local local_credentials_file="$local_backup_dir/credentials.json"
    local requires_remote=false

    credentials_folder_name="${credentials_folder_name%/}"
    if [[ -z "$credentials_folder_name" ]]; then
        credentials_folder_name=".credentials"
    fi
    local credentials_subpath="$credentials_folder_name/credentials.json"

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
    if [ -t 0 ] && ! $is_dry_run; then
        show_restore_plan "$restore_scope" "$github_repo" "$branch" "$workflows_mode" "$credentials_mode"
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
        log WARN "Running restore non-interactively (workflows mode: $(format_storage_value $workflows_mode), credentials mode: $(format_storage_value $credentials_mode)). Proceeding without confirmation."
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

    if [[ "$workflows_mode" != "0" ]]; then
        local workflow_output
    workflow_output=$(docker exec "$container_id" sh -c "n8n export:workflow --all --output=$container_pre_workflows" 2>&1) || {
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

    if [[ "$credentials_mode" != "0" ]]; then
        if ! $backup_failed; then
            local cred_output
            cred_output=$(docker exec "$container_id" sh -c "n8n export:credentials --all --decrypted --output=$container_pre_credentials" 2>&1) || {
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
        if [[ "$workflows_mode" != "0" ]]; then
            docker cp "${container_id}:${container_pre_workflows}" "$pre_workflows" || true
        fi
        if [[ "$credentials_mode" != "0" ]]; then
            docker cp "${container_id}:${container_pre_credentials}" "$pre_credentials" || true
        fi
        dockExec "$container_id" "rm -f $container_pre_workflows $container_pre_credentials" false || true
    else
        log INFO "Copying current data to host backup directory..."
        local copy_failed=false
        if [[ "$workflows_mode" != "0" ]]; then
            if $is_dry_run; then
                log DRYRUN "Would copy ${container_id}:${container_pre_workflows} to $pre_workflows"
            elif ! docker cp "${container_id}:${container_pre_workflows}" "$pre_workflows"; then copy_failed=true; fi
        fi
        if [[ "$credentials_mode" != "0" ]]; then
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

    # --- 2. Prepare backup sources based on selected modes ---
    log HEADER "Step 2: Preparing Backup Sources"

    if [[ "$workflows_mode" == "2" || "$credentials_mode" == "2" ]]; then
        requires_remote=true
    fi

    if $requires_remote; then
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

        selected_base_dir="$download_dir"

        cd "$download_dir" || {
            log ERROR "Failed to change to download directory"
            rm -rf "$download_dir"
            if [ -n "$pre_restore_dir" ]; then log WARN "Pre-restore backup kept at: $pre_restore_dir"; fi
            return 1
        }

        local backup_dirs=()
        readarray -t backup_dirs < <(find . -type d -name "backup_*" | sort -r)

        if [ ${#backup_dirs[@]} -gt 0 ]; then
            log INFO "Found ${#backup_dirs[@]} dated backup(s):"

            if ! [ -t 0 ]; then
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
                folder_manifest_path="$selected_base_dir/.n8n-folder-structure.json"
                folder_manifest_base="$selected_base_dir"
                log INFO "Detected folder structure manifest: $folder_manifest_path"
            fi

            if ! $folder_structure_backup; then
                if [ -f "$selected_base_dir/workflows.json" ]; then
                    repo_workflows="$selected_base_dir/workflows.json"
                    log SUCCESS "Found workflows.json in selected backup"
                elif [ -f "$download_dir/workflows.json" ]; then
                    repo_workflows="$download_dir/workflows.json"
                    log SUCCESS "Found workflows.json in repository root"
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

        cd - >/dev/null 2>&1 || true
    else
        log INFO "Skipping Git fetch; relying on local backups only."
    fi

    if [[ "$workflows_mode" == "1" ]]; then
        repo_workflows="$local_workflows_file"
        log INFO "Selected local workflows backup: $repo_workflows"
    fi

    if [[ "$credentials_mode" == "1" ]]; then
        repo_credentials="$local_credentials_file"
        log INFO "Selected local credentials backup: $repo_credentials"
    fi

    # Validate files before proceeding
    log INFO "Validating files for import..."
    local file_validation_passed=true
    
    if [[ "$workflows_mode" != "0" ]]; then
        if $folder_structure_backup; then
            if ! jq -e '.workflows | length > 0' "$folder_manifest_path" >/dev/null 2>&1; then
                log ERROR "Folder structure manifest is invalid or empty: $folder_manifest_path"
                file_validation_passed=false
            else
                local manifest_count
                manifest_count=$(jq -r '.workflows | length' "$folder_manifest_path" 2>/dev/null || echo 0)
                log SUCCESS "Folder structure manifest validated ($manifest_count workflow file(s) detected)"
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
                cred_source_desc="Git repository ($credentials_folder_name)"
                if [[ "$repo_credentials" != *"/$credentials_subpath" ]]; then
                    cred_source_desc="Git repository (legacy layout)"
                fi
            fi
            log SUCCESS "Credentials file validated for import from $cred_source_desc"
        fi
    fi
    
    if [ "$file_validation_passed" != "true" ]; then
        log ERROR "File validation failed. Cannot proceed with restore."
        if [[ -n "$download_dir" ]]; then
            rm -rf "$download_dir"
        fi
        if [ -n "$pre_restore_dir" ]; then log WARN "Pre-restore backup kept at: $pre_restore_dir"; fi
        return 1
    fi
    
    # --- 3. Import Data ---
    log HEADER "Step 3: Importing Data into n8n"

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
    if [[ "$credentials_mode" != "0" ]]; then
        # Only attempt decryption if not a dry run and file is not empty
        if [ "$is_dry_run" != "true" ] && [ -s "$repo_credentials" ]; then
            # Check if file appears to be encrypted (has base64 data fields)
            if jq -e '.[0] | has("data") and (.data | type == "string")' "$repo_credentials" >/dev/null 2>&1; then
                log INFO "Encrypted credentials detected. Decrypting before import..."
                decrypt_tmpfile="$(mktemp -t n8n-decrypted-XXXXXXXX.json)"
                # Prompt for key and decrypt using lib/decrypt.sh
                source "$(dirname "$0")/../lib/decrypt.sh"
                check_dependencies
                local decryption_key
                read -r -s -p "Enter encryption key for credentials decryption: " decryption_key
                echo >&2
                if decrypt_credentials_file "$decryption_key" "$repo_credentials" "$decrypt_tmpfile"; then
                    log SUCCESS "Credentials decrypted successfully."
                    credentials_to_import="$decrypt_tmpfile"
                else
                    log ERROR "Failed to decrypt credentials. Aborting restore."
                    rm -f "$decrypt_tmpfile"
                    if [[ -n "$download_dir" ]]; then
                        rm -rf "$download_dir"
                    fi
                    if [ -n "$pre_restore_dir" ]; then log WARN "Pre-restore backup kept at: $pre_restore_dir"; fi
                    return 1
                fi
            fi
        fi
    fi

    log INFO "Copying files to container..."
    local copy_status="success"

    # Copy workflow file if needed
    if [[ "$workflows_mode" != "0" ]]; then
        if $folder_structure_backup; then
            if [ "$is_dry_run" = "true" ]; then
                log DRYRUN "Would stage structured workflows in ${container_import_workflows} using manifest $folder_manifest_path"
            else
                if ! dockExec "$container_id" "rm -rf $container_import_workflows && mkdir -p $container_import_workflows" false; then
                    log ERROR "Failed to prepare container directory for structured workflow import."
                    copy_status="failed"
                elif ! copy_manifest_workflows_to_container "$folder_manifest_path" "$folder_manifest_base" "$container_id" "$container_import_workflows"; then
                    log ERROR "Failed to copy structured workflow files into container."
                    copy_status="failed"
                else
                    log SUCCESS "Structured workflow files prepared in container directory $container_import_workflows"
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
        if [ -n "$pre_restore_dir" ]; then log WARN "Pre-restore backup kept at: $pre_restore_dir"; fi
        return 1
    fi
    
    # Import data
    log INFO "Importing data into n8n..."
    local import_status="success"
    
    # Import workflows if needed
    if [[ "$workflows_mode" != "0" ]]; then
        if [ "$is_dry_run" = "true" ]; then
            if [[ "$workflow_import_mode" == "directory" ]]; then
                log DRYRUN "Would run: n8n import:workflow --separate --input=$container_import_workflows"
            else
                log DRYRUN "Would run: n8n import:workflow --input=$container_import_workflows"
            fi
        else
            log INFO "Importing workflows..."
            if [[ "$workflow_import_mode" == "directory" ]]; then
                if ! dockExec "$container_id" "n8n import:workflow --separate --input=$container_import_workflows" "$is_dry_run"; then
                    log ERROR "Failed to import workflows from structured directory"
                    import_status="failed"
                else
                    log SUCCESS "Structured workflows imported successfully"
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
    
    if [[ "$workflows_mode" != "0" ]] && $folder_structure_backup && [ "$is_dry_run" != "true" ] && [ "$import_status" != "failed" ] && [[ "$apply_folder_structure" == "true" ]]; then
        if ! apply_folder_structure_from_manifest "$folder_manifest_path" "$container_id" "$is_dry_run" "$container_import_credentials"; then
            log WARN "Folder structure restoration encountered issues; workflows may require manual reorganization."
        fi
    fi

    # Clean up temporary files in container
    if [ "$is_dry_run" != "true" ]; then
        log INFO "Cleaning up temporary files in container..."
        dockExec "$container_id" "rm -rf $container_import_workflows $container_import_credentials" "$is_dry_run" || true
    fi
    
    # Clean up downloaded repository
    if [[ -n "$download_dir" ]]; then
        rm -rf "$download_dir"
    fi
    
    # Handle restore result
    if [ "$import_status" = "failed" ]; then
        log WARN "Restore partially completed with some errors. Check logs for details."
        if [ -n "$pre_restore_dir" ]; then 
            log WARN "Pre-restore backup kept at: $pre_restore_dir" 
        fi
        return 1
    fi
    
    # Success - cleanup pre-restore backup
    if [ -n "$pre_restore_dir" ] && [ "$is_dry_run" != "true" ]; then
        rm -rf "$pre_restore_dir"
        log INFO "Pre-restore backup cleaned up."
    fi
    
    log HEADER "Restore Summary"
    log SUCCESS "✅ Restore completed successfully!"
    
    return 0
}