#!/usr/bin/env bash
# =========================================================
# lib/restore.sh - Restore operations for n8n-manager
# =========================================================
# All restore-related functions: restore process, rollback

# Source required modules
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/interactive.sh"

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

restore() {
    local container_id="$1"
    local github_token="$2"
    local github_repo="$3"
    local branch="$4"
    local restore_type="$5"
    local is_dry_run=$6

    log HEADER "Performing Restore from GitHub (Type: $restore_type)"
    if $is_dry_run; then log WARN "DRY RUN MODE ENABLED - NO CHANGES WILL BE MADE"; fi
    
    # Show restore plan for clarity
    if [ -t 0 ] && ! $is_dry_run; then
        show_restore_plan "$restore_type" "$github_repo" "$branch"
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

    if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
        local workflow_output
        workflow_output=$(docker exec "$container_id" n8n export:workflow --all --output=$container_pre_workflows 2>&1) || {
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

    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
        if ! $backup_failed; then
            local cred_output
            cred_output=$(docker exec "$container_id" n8n export:credentials --all --decrypted --output=$container_pre_credentials 2>&1) || {
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
        if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
            docker cp "${container_id}:${container_pre_workflows}" "$pre_workflows" || true
        fi
        if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
            docker cp "${container_id}:${container_pre_credentials}" "$pre_credentials" || true
        fi
        dockExec "$container_id" "rm -f $container_pre_workflows $container_pre_credentials" false || true
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

    # Check for dated backup directories and offer selection
    local dated_backup_found=false
    local selected_backup=""
    local backup_dirs=()
    
    cd "$download_dir" || { 
        log ERROR "Failed to change to download directory";
        rm -rf "$download_dir";
        if [ -n "$pre_restore_dir" ]; then log WARN "Pre-restore backup kept at: $pre_restore_dir"; fi;
        return 1;
    }
    
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
    
    # Find workflow and credentials files
    local repo_workflows=""
    local repo_credentials=""
    
    # First try dated backup if specified
    if $dated_backup_found; then
        local dated_path="${selected_backup#./}"
        log INFO "Looking for files in dated backup: $dated_path"
        
        if [ -f "${download_dir}/${dated_path}/workflows.json" ]; then
            repo_workflows="${download_dir}/${dated_path}/workflows.json"
            log SUCCESS "Found workflows.json in dated backup directory"
        fi
        
        if [ -f "${download_dir}/${dated_path}/credentials.json" ]; then
            repo_credentials="${download_dir}/${dated_path}/credentials.json"
            log SUCCESS "Found credentials.json in dated backup directory"
        fi
    fi
    
    # Fall back to repository root if files weren't found in dated backup
    if [ -z "$repo_workflows" ] && [ -f "${download_dir}/workflows.json" ]; then
        repo_workflows="${download_dir}/workflows.json"
        log SUCCESS "Found workflows.json in repository root"
    fi
    
    # Handle credentials - check local storage first, then Git repo
    local local_backup_dir="$HOME/n8n-backup"
    local local_credentials_file="$local_backup_dir/credentials.json"
    
    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
        log INFO "Checking for credentials in local secure storage..."
        
        # Check local storage first (preferred method)
        if [ -f "$local_credentials_file" ] && [ -s "$local_credentials_file" ]; then
            repo_credentials="$local_credentials_file"
            log SUCCESS "Found credentials in local secure storage: $local_credentials_file"
        # Check for dated backup credentials in Git
        elif [ -n "$selected_backup" ] && [ -f "${download_dir}${selected_backup}/credentials.json" ] && [ -s "${download_dir}${selected_backup}/credentials.json" ]; then
            repo_credentials="${download_dir}${selected_backup}/credentials.json"
            log WARN "Found credentials in Git repository dated backup (legacy method)"
            log WARN "⚠️  Security recommendation: Use newer backup method that stores credentials locally"
        # Check repository root for credentials
        elif [ -f "${download_dir}/credentials.json" ] && [ -s "${download_dir}/credentials.json" ]; then
            repo_credentials="${download_dir}/credentials.json"
            log WARN "Found credentials in Git repository root (legacy method)"
            log WARN "⚠️  Security recommendation: Use newer backup method that stores credentials locally"
        else
            log ERROR "No credentials found for $restore_type restore"
            log ERROR "Searched locations:"
            log ERROR "  • Local secure storage: $local_credentials_file (preferred)"
            if [ -n "$selected_backup" ]; then
                log ERROR "  • Git dated backup: ${download_dir}${selected_backup}/credentials.json"
            fi
            log ERROR "  • Git repository root: ${download_dir}/credentials.json"
            log ERROR "📝 To fix: Either use a backup that includes credentials, or restore workflows-only"
            
            rm -rf "$download_dir"
            if [ -n "$pre_restore_dir" ]; then log WARN "Pre-restore backup kept at: $pre_restore_dir"; fi
            return 1
        fi
    fi
    
    # Validate files before proceeding
    log INFO "Validating files for import..."
    local file_validation_passed=true
    
    if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
        if [ ! -f "$repo_workflows" ] || [ ! -s "$repo_workflows" ]; then
            log ERROR "Valid workflows.json not found for $restore_type restore"
            file_validation_passed=false
        else
            log SUCCESS "Workflows file validated for import"
        fi
    fi
    
    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
        if [ ! -f "$repo_credentials" ] || [ ! -s "$repo_credentials" ]; then
            log ERROR "Valid credentials.json not found for $restore_type restore"
            log ERROR "💡 Suggestion: Try --restore-type workflows to restore workflows only"
            file_validation_passed=false
        else
            local cred_source_desc="local secure storage"
            if [[ "$repo_credentials" != "$local_credentials_file" ]]; then
                cred_source_desc="Git repository (legacy backup)"
            fi
            log SUCCESS "Credentials file validated for import from $cred_source_desc"
        fi
    fi
    
    if [ "$file_validation_passed" != "true" ]; then
        log ERROR "File validation failed. Cannot proceed with restore."
        rm -rf "$download_dir"
        if [ -n "$pre_restore_dir" ]; then log WARN "Pre-restore backup kept at: $pre_restore_dir"; fi
        return 1
    fi
    
    # --- 3. Import Data ---
    log HEADER "Step 3: Importing Data into n8n"

    local container_import_workflows="/tmp/import_workflows.json"
    local container_import_credentials="/tmp/import_credentials.json"

    # --- Credentials decryption integration ---
    local credentials_to_import="$repo_credentials"
    local decrypt_tmpfile=""
    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
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
                    rm -rf "$download_dir"
                    if [ -n "$pre_restore_dir" ]; then log WARN "Pre-restore backup kept at: $pre_restore_dir"; fi
                    return 1
                fi
            fi
        fi
    fi

    log INFO "Copying files to container..."
    local copy_status="success"

    # Copy workflow file if needed
    if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
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

    # Copy credentials file if needed (use decrypted if available)
    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
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
        rm -rf "$download_dir"
        if [ -n "$pre_restore_dir" ]; then log WARN "Pre-restore backup kept at: $pre_restore_dir"; fi
        return 1
    fi
    
    # Import data
    log INFO "Importing data into n8n..."
    local import_status="success"
    
    # Import workflows if needed
    if [[ "$restore_type" == "all" || "$restore_type" == "workflows" ]]; then
        if [ "$is_dry_run" = "true" ]; then
            log DRYRUN "Would run: n8n import:workflow --input=$container_import_workflows"
        else
            log INFO "Importing workflows..."
            if ! dockExec "$container_id" "n8n import:workflow --input=$container_import_workflows" "$is_dry_run"; then
                # Try with --separate flag on failure
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
    
    # Import credentials if needed
    if [[ "$restore_type" == "all" || "$restore_type" == "credentials" ]]; then
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
    
    # Clean up temporary files in container
    if [ "$is_dry_run" != "true" ]; then
        log INFO "Cleaning up temporary files in container..."
        dockExec "$container_id" "rm -f $container_import_workflows $container_import_credentials" "$is_dry_run" || true
    fi
    
    # Clean up downloaded repository
    rm -rf "$download_dir"
    
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