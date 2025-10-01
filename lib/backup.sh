#!/usr/bin/env bash
# =========================================================
# lib/backup.sh - Backup operations for n8n-manager
# =========================================================
# All backup-related functions: archiving, rotation, backup process

# Source required modules
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/n8n-api.sh"
source "$(dirname "${BASH_SOURCE[0]}")/git.sh"

# Orchestrate folder structure creation with proper separation of concerns
create_folder_structure_with_git() {
    local container_id="$1"
    local target_dir="$2"
    local git_dir="$3"
    local is_dry_run="$4"
    local container_credentials_path="${5:-/tmp/credentials.json}"
    
    if [[ -z "$container_id" || -z "$target_dir" || -z "$git_dir" ]]; then
        log "ERROR" "Missing required parameters for folder structure creation"
        return 1
    fi
    
    if $is_dry_run; then
        log "DRYRUN" "Would create n8n folder structure with individual Git commits"
        return 0
    fi
    
    log INFO "Creating n8n folder structure with proper workflow organization..."
    
    # Step 1: Export individual workflow files from Docker container
    log DEBUG "Step 1: Exporting individual workflows from n8n container..."
    local temp_export_dir="$(mktemp -d -t n8n-workflows-XXXXXXXXXX)"

    if ! dockExec "$container_id" "rm -rf /tmp/workflow_exports && mkdir -p /tmp/workflow_exports" false; then
        log ERROR "Failed to prepare workflow export directory inside container"
        rm -rf "$temp_export_dir"
        return 1
    fi

    local export_cmd="n8n export:workflow --all --separate --output=/tmp/workflow_exports/"
    if ! dockExec "$container_id" "$export_cmd" false; then
        log ERROR "Failed to export individual workflow files from container"
        rm -rf "$temp_export_dir"
        return 1
    fi
    
    # Copy exported files from container to local temp directory
    if ! docker cp "${container_id}:/tmp/workflow_exports/" "$temp_export_dir/"; then
        log ERROR "Failed to copy exported workflow files from container"
        rm -rf "$temp_export_dir"
        return 1
    fi
    
    log SUCCESS "Exported individual workflow files to temporary directory"
    
    # Step 2: Get folder organization mapping from n8n API
    log DEBUG "Step 2: Fetching folder structure mapping from n8n API..."
    local folder_mapping_json
    if ! folder_mapping_json=$(get_workflow_folder_mapping "$container_id" "$container_credentials_path"); then
        log ERROR "Failed to get folder structure mapping from n8n API"
        log WARN "Falling back to flat file structure"
        # Fallback: copy all files to target directory using sanitized workflow names
        if ! copy_workflows_flat_with_names "$temp_export_dir/workflow_exports" "$target_dir"; then
            log ERROR "Failed to copy workflows to Git repository"
            rm -rf "$temp_export_dir"
            return 1
        fi
        rm -rf "$temp_export_dir"
        return 0
    fi
    
    log SUCCESS "Retrieved folder structure mapping from n8n API"
    
    # Step 3: Organize files according to folder structure and commit to Git
    log DEBUG "Step 3: Organizing workflows into folder structure..."
    if ! organize_workflows_by_folders "$temp_export_dir/workflow_exports" "$target_dir" "$folder_mapping_json" "$git_dir"; then
        log ERROR "Failed to organize workflows by folders"
        rm -rf "$temp_export_dir"
        return 1
    fi
    
    log SUCCESS "n8n folder structure created and committed to repository"
    rm -rf "$temp_export_dir"
    return 0
}

print_folder_structure_preview() {
    local base_dir="$1"
    local max_files=${2:-5}

    if [[ ! -d "$base_dir" ]]; then
        log WARN "Folder structure preview skipped - directory missing: $base_dir"
        return
    fi

    log INFO "Workflow folder structure preview:"

    local base_prefix="${base_dir%/}/"

    # Handle JSON files directly under the base directory
    local root_files=()
    while IFS= read -r file; do
        root_files+=("$file")
    done < <(find "$base_dir" -maxdepth 1 -type f -name '*.json' | sort | head -n "$max_files")

    if ((${#root_files[@]} > 0)); then
        log INFO "(root)"
        for file in "${root_files[@]}"; do
            log INFO "- $(basename "$file")"
        done
        local total_root
        total_root=$(find "$base_dir" -maxdepth 1 -type f -name '*.json' | wc -l)
        if (( total_root > ${#root_files[@]} )); then
            log INFO "- < + $((total_root - ${#root_files[@]})) more >"
        fi
    fi

    while IFS= read -r dir; do
        local relative="${dir#$base_prefix}"
        if [[ "$relative" == "$dir" ]]; then
            relative=$(basename "$dir")
        fi

        IFS='/' read -r -a parts <<< "$relative"
        local depth=${#parts[@]}
        local name_index=$((depth - 1))
        local name="${parts[$name_index]}"
        local prefix=""
        if (( depth > 1 )); then
            for ((i=1; i<depth; i++)); do
                prefix+="-"
            done
            prefix+=" "
        fi

        log INFO "${prefix}${name}"

        local files=()
        while IFS= read -r file; do
            files+=("$file")
        done < <(find "$dir" -maxdepth 1 -type f -name '*.json' | sort | head -n "$max_files")

        if ((${#files[@]} > 0)); then
            local file_prefix=""
            for ((i=0; i<depth; i++)); do
                file_prefix+="-"
            done
            file_prefix+=" "

            for file in "${files[@]}"; do
                log INFO "${file_prefix}$(basename "$file")"
            done

            local total_count
            total_count=$(find "$dir" -maxdepth 1 -type f -name '*.json' | wc -l)
            if (( total_count > ${#files[@]} )); then
                log INFO "${file_prefix}< + $((total_count - ${#files[@]})) more >"
            fi
        fi
    done < <(find "$base_dir" -mindepth 1 -type d -not -path '*/.git*' | sort)
}

trim_trailing_spaces_and_dots() {
    local value="$1"
    while [[ "$value" =~ [[:space:].]$ ]]; do
        value="${value%?}"
    done
    printf '%s\n' "$value"
}

generate_unique_workflow_filename() {
    local destination_dir="$1"
    local workflow_id="$2"
    local workflow_name="$3"
    local registry_name="$4"

    local -n registry_ref="$registry_name"

    local base_name
    base_name="$(sanitize_workflow_filename_part "$workflow_name" "$workflow_id")"
    local original_base="$base_name"

    local suffix=0
    local candidate_filename=""

    while true; do
        local suffix_text=""
        if (( suffix > 0 )); then
            suffix_text=" (${suffix})"
        fi

        local allowed_length=$((152 - ${#suffix_text}))
        if (( allowed_length <= 0 )); then
            allowed_length=1
        fi

        local candidate_base="$base_name"
        if (( ${#candidate_base} > allowed_length )); then
            candidate_base="${candidate_base:0:allowed_length}"
            candidate_base="$(trim_trailing_spaces_and_dots "$candidate_base")"
            if [[ -z "$candidate_base" ]]; then
                candidate_base="${original_base:0:allowed_length}"
                candidate_base="$(trim_trailing_spaces_and_dots "$candidate_base")"
                if [[ -z "$candidate_base" ]]; then
                    candidate_base="Workflow"
                fi
            fi
        fi

        local candidate="$candidate_base$suffix_text"
        candidate_filename="$candidate.json"
        local candidate_path="$destination_dir/$candidate_filename"

        local existing_id=""
        if [[ -f "$candidate_path" ]]; then
            existing_id=$(jq -r '.id // empty' "$candidate_path" 2>/dev/null)
        fi

        if [[ -n "$workflow_id" && "$existing_id" == "$workflow_id" ]]; then
            registry_ref["$candidate_path"]=1
            printf '%s\n' "$candidate_filename"
            return 0
        fi

        if [[ ! -e "$candidate_path" && -z "${registry_ref[$candidate_path]+set}" ]]; then
            registry_ref["$candidate_path"]=1
            printf '%s\n' "$candidate_filename"
            return 0
        fi

        suffix=$((suffix + 1))
    done
}

prettify_json_file() {
    local file_path="$1"
    local is_dry_run="${2:-false}"

    if [[ ! -f "$file_path" ]]; then
        return 0
    fi

    if $is_dry_run; then
        log DEBUG "Skipping JSON prettify (dry run): $file_path"
        return 0
    fi

    local file_dir
    file_dir="$(dirname "$file_path")"

    local tmp_file
    tmp_file=$(mktemp "$file_dir/.n8n-pretty-json.XXXXXXXX") 2>/dev/null || {
        log WARN "Failed to allocate temp file for prettifying: $file_path"
        return 1
    }

    local original_mode=""
    if stat -c '%a' "$file_path" >/dev/null 2>&1; then
        original_mode=$(stat -c '%a' "$file_path" 2>/dev/null || true)
    elif stat -f '%Lp' "$file_path" >/dev/null 2>&1; then
        original_mode=$(stat -f '%Lp' "$file_path" 2>/dev/null || true)
    fi

    if ! jq '.' "$file_path" >"$tmp_file" 2>/dev/null; then
        log WARN "jq failed to prettify JSON file: $file_path"
        rm -f "$tmp_file"
        return 1
    fi

    if ! mv "$tmp_file" "$file_path" 2>/dev/null; then
        if ! cat "$tmp_file" >"$file_path"; then
            log WARN "Failed to write prettified JSON back to file: $file_path"
            rm -f "$tmp_file"
            return 1
        fi
        rm -f "$tmp_file"
    fi

    if [[ -n "$original_mode" ]]; then
        chmod "$original_mode" "$file_path" 2>/dev/null || true
    fi

    log DEBUG "Prettified JSON file: $file_path"
    return 0
}

prettify_json_tree() {
    local root_dir="$1"
    local is_dry_run="${2:-false}"

    if [[ ! -d "$root_dir" ]]; then
        return 0
    fi

    if $is_dry_run; then
        log DEBUG "Skipping JSON tree prettify (dry run): $root_dir"
        return 0
    fi

    local all_success=true
    while IFS= read -r -d '' json_file; do
        if ! prettify_json_file "$json_file" "$is_dry_run"; then
            all_success=false
        fi
    done < <(find "$root_dir" -type f -name '*.json' -print0)

    if ! $all_success; then
        log WARN "Completed JSON prettify with warnings under: $root_dir"
        return 1
    fi

    return 0
}

copy_workflows_flat_with_names() {
    local source_dir="$1"
    local target_dir="$2"

    if [[ -z "$source_dir" || ! -d "$source_dir" ]]; then
        log WARN "Fallback copy skipped - source directory missing: $source_dir"
        return 1
    fi

    if ! mkdir -p "$target_dir"; then
        log WARN "Fallback copy failed - could not ensure target directory: $target_dir"
        return 1
    fi

    local -A registry=()
    local success=true

    while IFS= read -r -d '' workflow_file; do
        local workflow_id
        workflow_id=$(jq -r '.id // empty' "$workflow_file" 2>/dev/null)
        local workflow_name
        workflow_name=$(jq -r '.name // "Unnamed Workflow"' "$workflow_file" 2>/dev/null)

        local filename
        filename=$(generate_unique_workflow_filename "$target_dir" "$workflow_id" "$workflow_name" registry)

        if [[ -z "$filename" ]]; then
            log WARN "Skipped workflow during fallback - could not derive filename"
            success=false
            continue
        fi

        if ! cp "$workflow_file" "$target_dir/$filename"; then
            log WARN "Failed to copy workflow to fallback target: $filename"
            success=false
            continue
        fi

        if ! prettify_json_file "$target_dir/$filename"; then
            log WARN "Failed to prettify workflow JSON: $filename"
            success=false
            continue
        fi
    done < <(find "$source_dir" -type f -name "*.json" -print0)

    if $success; then
        log SUCCESS "Workflows copied to Git repository (flat structure fallback)"
        return 0
    fi

    return 1
}

organize_workflows_by_folders() {
    local source_dir="$1"
    local target_dir="$2"
    local mapping_json="$3"
    local git_dir="$4"

    if [[ -z "$source_dir" || ! -d "$source_dir" ]]; then
        log ERROR "Workflow export directory missing: $source_dir"
        return 1
    fi

    if [[ -z "$target_dir" ]]; then
        log ERROR "Target directory not specified for workflow organization"
        return 1
    fi

    if [[ -z "$git_dir" || ! -d "$git_dir" ]]; then
        log ERROR "Git directory not accessible: $git_dir"
        return 1
    fi

    if ! mkdir -p "$target_dir"; then
        log ERROR "Failed to ensure target directory exists: $target_dir"
        return 1
    fi

    local mapping_file
    mapping_file=$(mktemp -t n8n-workflow-mapping-XXXXXXXX.json)
    printf '%s' "$mapping_json" > "$mapping_file"

    if ! jq -e '.workflowsById | type == "object"' "$mapping_file" >/dev/null 2>&1; then
        log ERROR "Workflow mapping JSON missing workflowsById object"
        local debug_preview
    debug_preview=$(head -c 500 "$mapping_file" 2>/dev/null || echo "<unavailable>")
    local mapping_size
    mapping_size=$(wc -c < "$mapping_file" 2>/dev/null || echo 0)
    log DEBUG "Mapping JSON preview (first 500 chars): ${debug_preview}$( [ "$mapping_size" -gt 500 ] && echo '…')"
        log DEBUG "Full mapping saved for inspection at: $mapping_file"
        return 1
    fi

    local new_count=0
    local updated_count=0
    local unchanged_count=0
    local deleted_count=0
    local commit_fail=false

    local git_prefix="${git_dir%/}/"
    local -A expected_files=()
    local -A filename_registry=()

    while IFS= read -r -d '' workflow_file; do
        local workflow_id
        workflow_id=$(jq -r '.id // empty' "$workflow_file" 2>/dev/null)

        if [[ -z "$workflow_id" ]]; then
            log WARN "Skipping workflow file without ID: $workflow_file"
            continue
        fi

        local workflow_name
        workflow_name=$(jq -r '.name // "Unnamed Workflow"' "$workflow_file" 2>/dev/null)

        local relative_path
        relative_path=$(jq -r --arg id "$workflow_id" '.workflowsById[$id].relativePath // empty' "$mapping_file" 2>/dev/null)
        local display_path
        display_path=$(jq -r --arg id "$workflow_id" '.workflowsById[$id].displayPath // empty' "$mapping_file" 2>/dev/null)

        if [[ -z "$relative_path" || "$relative_path" == "null" ]]; then
            relative_path="Personal"
        fi

        if [[ -z "$display_path" || "$display_path" == "null" ]]; then
            display_path="$relative_path"
        fi

        relative_path="${relative_path#/}"
        relative_path="${relative_path%/}"

        local destination_dir="$target_dir/$relative_path"
        if ! mkdir -p "$destination_dir"; then
            log WARN "Failed to create destination directory: $destination_dir"
            commit_fail=true
            continue
        fi

        local generated_filename
        generated_filename=$(generate_unique_workflow_filename "$destination_dir" "$workflow_id" "$workflow_name" filename_registry)

        if [[ -z "$generated_filename" ]]; then
            log WARN "Skipping workflow ${workflow_id:-unknown} - unable to determine filename"
            commit_fail=true
            continue
        fi

        local target_file="$destination_dir/$generated_filename"
        expected_files["$target_file"]=1

        if [[ -f "$target_file" ]] && cmp -s "$workflow_file" "$target_file" 2>/dev/null; then
            unchanged_count=$((unchanged_count + 1))
            continue
        fi

        if ! cp "$workflow_file" "$target_file"; then
            log WARN "Failed to copy workflow ${workflow_id:-unknown} to $target_file"
            commit_fail=true
            continue
        fi

        if ! prettify_json_file "$target_file"; then
            log WARN "Failed to prettify workflow JSON: $target_file"
            commit_fail=true
        fi

        local relative_git_path=""
        if [[ "$target_file" == "$git_prefix"* ]]; then
            relative_git_path="${target_file#$git_prefix}"
        else
            log WARN "Workflow file resides outside Git directory: $target_file"
            commit_fail=true
            continue
        fi

        local is_new="true"
        if git -C "$git_dir" ls-files --error-unmatch "$relative_git_path" >/dev/null 2>&1; then
            is_new="false"
        fi

        if [[ "$is_new" == "true" ]]; then
            new_count=$((new_count + 1))
        else
            updated_count=$((updated_count + 1))
        fi

        local commit_label="$workflow_name"
        if [[ -n "$display_path" && "$display_path" != "$workflow_name" ]]; then
            commit_label="$workflow_name ($display_path)"
        fi

        if ! commit_individual_workflow "$relative_git_path" "$commit_label" "$git_dir" "$is_new"; then
            commit_fail=true
        fi
    done < <(find "$source_dir" -type f -name "*.json" -not -path "*/.git/*" -print0)

    while IFS= read -r -d '' existing_file; do
    if [[ -z "${expected_files[$existing_file]+set}" ]]; then
            local workflow_name
            workflow_name=$(jq -r '.name // empty' "$existing_file" 2>/dev/null)
            if [[ -z "$workflow_name" || "$workflow_name" == "null" ]]; then
                workflow_name=$(basename "$existing_file" ".json")
            fi

            local relative_git_path=""
            if [[ "$existing_file" == "$git_prefix"* ]]; then
                relative_git_path="${existing_file#$git_prefix}"
            else
                log WARN "Workflow deletion outside Git directory: $existing_file"
                commit_fail=true
                continue
            fi

            if ! rm -f "$existing_file"; then
                log WARN "Failed to remove obsolete workflow file: $existing_file"
                commit_fail=true
                continue
            fi

            if commit_deleted_workflow "$relative_git_path" "$workflow_name" "$git_dir"; then
                deleted_count=$((deleted_count + 1))
            else
                commit_fail=true
            fi
        fi
    done < <(find "$target_dir" -type f -name "*.json" -not -path "*/.git/*" -print0)

    while IFS= read -r -d '' empty_dir; do
        [[ "$empty_dir" == "$target_dir" ]] && continue
        rmdir "$empty_dir" 2>/dev/null || true
    done < <(find "$target_dir" -type d -empty -not -path "*/.git/*" -print0)

    log INFO "Workflow organization summary:"
    log INFO "  • New workflows: $new_count"
    log INFO "  • Updated workflows: $updated_count"
    log INFO "  • Unchanged workflows: $unchanged_count"
    log INFO "  • Deleted workflows: $deleted_count"

    rm -f "$mapping_file"

    print_folder_structure_preview "$target_dir"

    if $commit_fail; then
        log WARN "Completed with some issues during workflow organization"
        return 1
    fi

    return 0
}

# Archive credentials with rotation (keep 5-10 backups)
archive_credentials() {
    local source_file="$1"
    local backup_dir="$2"
    local is_dry_run="$3"
    local rotation_limit=${4:-10}  # 0=overwrite, number=keep N, unlimited=keep all

    if [ ! -f "$source_file" ]; then
        log WARN "Source credentials file not found: $source_file"
        return 1
    fi

    # Handle different rotation modes
    if [[ "$rotation_limit" == "0" ]]; then
        # Mode 0: Just overwrite, no archiving
        log DEBUG "Rotation disabled - credentials will be overwritten"
        return 0
    fi

    local archive_dir="$backup_dir/archive"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local archive_file="$archive_dir/credentials_${timestamp}.json"

    if $is_dry_run; then
        log DRYRUN "Would create archive directory: $archive_dir"
        log DRYRUN "Would archive credentials to: $archive_file"
        if [[ "$rotation_limit" == "unlimited" ]]; then
            log DRYRUN "Would keep unlimited credential archives"
        else
            log DRYRUN "Would rotate archives to keep max $rotation_limit files"
        fi
        return 0
    fi

    # Create archive directory
    if ! mkdir -p "$archive_dir"; then
        log ERROR "Failed to create archive directory: $archive_dir"
        return 1
    fi
    chmod 700 "$archive_dir" || log WARN "Could not set permissions on archive directory"

    # Archive current credentials
    if ! cp "$source_file" "$archive_file"; then
        log ERROR "Failed to archive credentials"
        return 1
    fi
    chmod 600 "$archive_file" || log WARN "Could not set permissions on archived credentials"
    log SUCCESS "Credentials archived to: $archive_file"

    # Handle rotation based on limit
    if [[ "$rotation_limit" == "unlimited" ]]; then
        log DEBUG "Unlimited rotation - keeping all credential archives"
    elif [[ "$rotation_limit" =~ ^[0-9]+$ ]] && [ "$rotation_limit" -gt 0 ]; then
        # Rotate archives - keep only the most recent N
        local archive_count
        archive_count=$(find "$archive_dir" -name "credentials_*.json" | wc -l)
        if [ "$archive_count" -gt "$rotation_limit" ]; then
            local files_to_remove=$((archive_count - rotation_limit))
            log INFO "Rotating credential archives - removing $files_to_remove old files (keeping $rotation_limit most recent)"
            
            # Remove oldest files (sort by name, which includes timestamp)
            find "$archive_dir" -name "credentials_*.json" | sort | head -n "$files_to_remove" | while read -r old_file; do
                rm -f "$old_file"
                log DEBUG "Removed old archive: $(basename "$old_file")"
            done
        fi
        log INFO "Credential archive rotation complete (keeping $rotation_limit most recent)"
    fi

    return 0
}

# Archive workflows with configurable rotation
archive_workflows() {
    local source_file="$1"
    local backup_dir="$2"
    local is_dry_run="$3"
    local rotation_limit=${4:-10}  # 0=overwrite, number=keep N, unlimited=keep all

    if [ ! -f "$source_file" ]; then
        log WARN "Source workflows file not found: $source_file"
        return 1
    fi

    # Handle different rotation modes
    if [[ "$rotation_limit" == "0" ]]; then
        # Mode 0: Just overwrite, no archiving
        log DEBUG "Rotation disabled - workflows will be overwritten"
        return 0
    fi

    local archive_dir="$backup_dir/archive"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local archive_file="$archive_dir/workflows_${timestamp}.json"

    if $is_dry_run; then
        log DRYRUN "Would create archive directory: $archive_dir"
        log DRYRUN "Would archive workflows to: $archive_file"
        log DRYRUN "Would rotate archives to keep max $rotation_limit files"
        return 0
    fi

    # Create archive directory
    if ! mkdir -p "$archive_dir"; then
        log ERROR "Failed to create archive directory: $archive_dir"
        return 1
    fi
    chmod 700 "$archive_dir" || log WARN "Could not set permissions on archive directory"

    # Archive current workflows
    if ! cp "$source_file" "$archive_file"; then
        log ERROR "Failed to archive workflows"
        return 1
    fi
    chmod 600 "$archive_file" || log WARN "Could not set permissions on archived workflows"
    log SUCCESS "Workflows archived to: $archive_file"

    # Handle rotation based on limit
    if [[ "$rotation_limit" == "unlimited" ]]; then
        log DEBUG "Unlimited rotation - keeping all workflow archives"
    elif [[ "$rotation_limit" =~ ^[0-9]+$ ]] && [ "$rotation_limit" -gt 0 ]; then
        # Rotate archives - keep only the most recent N
        local archive_count
        archive_count=$(find "$archive_dir" -name "workflows_*.json" | wc -l)
        if [ "$archive_count" -gt "$rotation_limit" ]; then
            local files_to_remove=$((archive_count - rotation_limit))
            log INFO "Rotating workflow archives - removing $files_to_remove old files (keeping $rotation_limit most recent)"
            
            # Remove oldest files (sort by name, which includes timestamp)
            find "$archive_dir" -name "workflows_*.json" | sort | head -n "$files_to_remove" | while read -r old_file; do
                rm -f "$old_file"
                log DEBUG "Removed old archive: $(basename "$old_file")"
            done
        fi
        log INFO "Workflow archive rotation complete (keeping $rotation_limit most recent)"
    fi
    return 0
}

rotate_local_timestamped_backups() {
    local base_backup_dir="$1"
    local rotation_limit=${2:-10}  # 0=overwrite, number=keep N, unlimited=keep all
    local is_dry_run="$3"

    if [ ! -d "$base_backup_dir" ]; then
        log WARN "Base backup directory not found: $base_backup_dir"
        return 1
    fi

    # Handle different rotation modes
    if [[ "$rotation_limit" == "0" ]]; then
        log DEBUG "Rotation disabled for timestamped directories - they accumulate until manually cleaned"
        return 0
    elif [[ "$rotation_limit" == "unlimited" ]]; then
        log DEBUG "Unlimited rotation - keeping all timestamped backup directories"
        return 0
    elif ! [[ "$rotation_limit" =~ ^[0-9]+$ ]]; then
        log WARN "Invalid rotation limit: $rotation_limit - defaulting to 10"
        rotation_limit=10
    fi

    # Find timestamped directories (format: YYYY-MM-DD_HH-MM-SS)
    local timestamped_dirs=()
    while IFS= read -r -d '' dir; do
        timestamped_dirs+=("$dir")
    done < <(find "$base_backup_dir" -maxdepth 1 -type d -name "*-*-*_*-*-*" -print0 | sort -z)

    local backup_count=${#timestamped_dirs[@]}
    if [ "$backup_count" -gt "$rotation_limit" ]; then
        local dirs_to_remove=$((backup_count - rotation_limit))
        log INFO "Rotating local timestamped backups - removing $dirs_to_remove old directories (keeping $rotation_limit most recent)"
        
        if $is_dry_run; then
            for ((i=0; i<dirs_to_remove; i++)); do
                log DRYRUN "Would remove old backup directory: $(basename "${timestamped_dirs[$i]}")"
            done
        else
            # Remove oldest directories
            for ((i=0; i<dirs_to_remove; i++)); do
                rm -rf "${timestamped_dirs[$i]}"
                log DEBUG "Removed old backup directory: $(basename "${timestamped_dirs[$i]}")"
            done
        fi
    else
        log DEBUG "Local backup rotation: keeping all $backup_count directories (under limit of $rotation_limit)"
    fi

    return 0
}

# Generate intelligent commit messages based on workflow changes
generate_workflow_commit_message() {
    local target_dir="$1"
    local is_dry_run="$2"
    
    # Count changes by examining Git status
    local new_files updated_files deleted_files
    
    if [[ $is_dry_run == true ]]; then
        echo "Backup workflow changes (dry run)"
        return 0
    fi
    
    # Use git status to detect changes
    pushd "$target_dir" > /dev/null || return 1
    
    # Get added files (new workflows)
    new_files=$(git status --porcelain 2>/dev/null | grep "^A " | wc -l)
    # Get modified files (updated workflows)  
    updated_files=$(git status --porcelain 2>/dev/null | grep "^M " | wc -l)
    # Get deleted files (removed workflows)
    deleted_files=$(git status --porcelain 2>/dev/null | grep "^D " | wc -l)
    
    popd > /dev/null || return 1
    
    # Generate appropriate commit message
    local commit_parts=()
    if [[ $new_files -gt 0 ]]; then
        commit_parts+=("$new_files new")
    fi
    if [[ $updated_files -gt 0 ]]; then
        commit_parts+=("$updated_files updated")
    fi
    if [[ $deleted_files -gt 0 ]]; then
        commit_parts+=("$deleted_files deleted")
    fi
    
    if [[ ${#commit_parts[@]} -eq 0 ]]; then
        echo "Workflow backup - no changes detected"
    elif [[ ${#commit_parts[@]} -eq 1 ]]; then
        echo "Workflow backup - ${commit_parts[0]} workflow(s)"
    else
        local message="Workflow backup - "
        for i in "${!commit_parts[@]}"; do
            if [[ $i -eq $((${#commit_parts[@]} - 1)) ]]; then
                message="${message} and ${commit_parts[$i]}"
            elif [[ $i -eq 0 ]]; then
                message="${message}${commit_parts[$i]}"
            else
                message="${message}, ${commit_parts[$i]}"
            fi
        done
        message="${message} workflow(s)"
        echo "$message"
    fi
}

backup() {
    local container_id="$1"
    local github_token="$2"
    local github_repo="$3"
    local branch="$4"
    local use_dated_backup=$5      # Boolean: true/false instead of string
    local is_dry_run=$6            # Boolean: true/false instead of string  
    local workflows=$7             # Numeric: 0=disabled, 1=local, 2=remote
    local credentials=$8           # Numeric: 0=disabled, 1=local, 2=remote
    local folder_structure_enabled=${9:-false} # Boolean: true if folder structure enabled
    local local_backup_path="${10:-$HOME/n8n-backup}"  # Local backup path (default: ~/n8n-backup)
    local local_rotation_limit="${11:-10}"  # Local rotation limit (default: 10)
    
    # Make container_id globally available for API functions
    export container_id="$container_id"
    
    # Derive storage descriptions for logging
    local workflows_desc="disabled"
    local credentials_desc="disabled"
    case "$workflows" in
        0) workflows_desc="disabled" ;;
        1) workflows_desc="local" ;;
        2) workflows_desc="remote" ;;
    esac
    case "$credentials" in
        0) credentials_desc="disabled" ;;
        1) credentials_desc="local" ;;
        2) credentials_desc="remote" ;;
    esac
    
    # Derive convenience boolean flags for easier logic
    local workflows_enabled=$( [[ $workflows != 0 ]] && echo true || echo false )
    local credentials_enabled=$( [[ $credentials != 0 ]] && echo true || echo false )
    local needs_github=$( [[ $workflows == 2 ]] || [[ $credentials == 2 ]] && echo true || echo false )
    local needs_local_path=$( [[ $workflows == 1 ]] || [[ $credentials == 1 ]] && echo true || echo false )
    
    log HEADER "Performing Backup - Workflows: $workflows_desc, Credentials: $credentials_desc"
    if $is_dry_run; then log WARN "DRY RUN MODE ENABLED - NO CHANGES WILL BE MADE"; fi
    
    # Validate that at least one backup type is enabled
    if [[ $workflows == 0 && $credentials == 0 ]]; then
        log ERROR "Both workflows and credentials are disabled. Nothing to backup!"
        return 1
    fi
    
    # Show security warnings
    if [[ $workflows == 2 ]]; then
        log WARN "⚠️  Workflows will be stored in Git repository"
    fi
    if [[ $credentials == 2 ]]; then
        if [[ "${credentials_encrypted:-true}" == "false" ]]; then
            log WARN "⚠️  SECURITY WARNING: Decrypted credentials will be pushed to Git repository!"
        else
            log INFO "🔐 Credentials will be pushed to Git repository encrypted by n8n."
        fi
    fi
    if [[ $workflows == 1 && $credentials == 1 ]]; then
        log INFO "🔒 Security: Both workflows and credentials stored locally only"
    fi

    # Setup local backup storage directory with optional timestamping
    local base_backup_dir="$local_backup_path"
    local local_backup_dir="$base_backup_dir"
    
    # Apply timestamping to local storage if requested
    if [[ $use_dated_backup == true ]] && [[ $needs_local_path == true ]]; then
        local backup_timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
        local_backup_dir="$base_backup_dir/$backup_timestamp"
        log INFO "📅 Using timestamped local backup directory: $backup_timestamp"
    fi
    
    local local_workflows_file="$local_backup_dir/workflows.json"
    local local_credentials_file="$local_backup_dir/credentials.json"
    local local_env_file="$local_backup_dir/.env"
    
    if ! $is_dry_run; then
        if ! mkdir -p "$local_backup_dir"; then
            log ERROR "Failed to create local backup directory: $local_backup_dir"
            return 1
        fi
        chmod 700 "$local_backup_dir" || log WARN "Could not set permissions on local backup directory"
        
        # Also ensure base directory has proper permissions
        if [[ "$local_backup_dir" != "$base_backup_dir" ]]; then
            chmod 700 "$base_backup_dir" || log WARN "Could not set permissions on base backup directory"
        fi
        
        log SUCCESS "Local backup directory ready: $local_backup_dir"
    else
        log DRYRUN "Would create local backup directory: $local_backup_dir"
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d -t n8n-backup-XXXXXXXXXX)
    log DEBUG "Created temporary directory: $tmp_dir"

    local container_workflows="/tmp/workflows.json"
    local container_credentials_encrypted="/tmp/credentials.json"
    local container_credentials_decrypted="/tmp/credentials.decrypted.json"
    local container_env="/tmp/.env"

    local container_credentials_backup_path="$container_credentials_encrypted"
    if [[ "${credentials_encrypted:-true}" == "false" ]]; then
        container_credentials_backup_path="$container_credentials_decrypted"
    fi

    local git_required=false
    if [[ $workflows == 2 ]] || [[ $credentials == 2 ]] || [[ "$folder_structure_enabled" == true ]]; then
        git_required=true
    fi

    if [[ "$git_required" == true ]]; then
        # --- Git Setup First --- 
        log INFO "Preparing Git repository for backup..."
        local git_repo_url="https://${github_token}@github.com/${github_repo}.git"

        log DEBUG "Initializing Git repository in $tmp_dir"
        if ! git -C "$tmp_dir" init -q; then log ERROR "Git init failed."; rm -rf "$tmp_dir"; return 1; fi
        log DEBUG "Adding remote 'origin' with URL $git_repo_url"
        if ! git -C "$tmp_dir" remote add origin "$git_repo_url" 2>/dev/null; then
            log WARN "Git remote 'origin' already exists. Setting URL..."
            if ! git -C "$tmp_dir" remote set-url origin "$git_repo_url"; then log ERROR "Git set-url failed."; rm -rf "$tmp_dir"; return 1; fi
        fi

        log INFO "Configuring Git user identity for commit..."
        if ! git -C "$tmp_dir" config user.email "n8n-backup-script@localhost"; then log ERROR "Failed to set Git user email."; rm -rf "$tmp_dir"; return 1; fi
        if ! git -C "$tmp_dir" config user.name "n8n Backup Script"; then log ERROR "Failed to set Git user name."; rm -rf "$tmp_dir"; return 1; fi

        log INFO "Fetching remote branch '$branch'..."
        local branch_exists=true
        if ! git -C "$tmp_dir" fetch --depth 1 origin "$branch" 2>/dev/null; then
            log WARN "Branch '$branch' not found on remote or repo is empty. Will create branch."
            branch_exists=false
            if ! $is_dry_run; then
                 if ! git -C "$tmp_dir" checkout -b "$branch"; then log ERROR "Git checkout -b failed."; rm -rf "$tmp_dir"; return 1; fi
            else
                 log DRYRUN "Would create and checkout new branch '$branch'"
            fi
        else
            if ! $is_dry_run; then
                if ! git -C "$tmp_dir" checkout "$branch"; then log ERROR "Git checkout failed."; rm -rf "$tmp_dir"; return 1; fi
            else
                log DRYRUN "Would checkout existing branch '$branch'"
            fi
        fi
        log SUCCESS "Git repository initialized and branch '$branch' checked out."
    else
        log DEBUG "Skipping Git repository preparation (local-only backup)."
    fi

    # --- Export Data --- 
    log INFO "Exporting data from n8n container..."
    local export_failed=false
    local no_data_found=false

    # Export workflows based on storage mode
    local container_workflows_dir="/tmp/workflows"
    if [[ $workflows == 2 ]]; then
        log INFO "Exporting individual workflow files for Git folder structure..."
        if ! dockExec "$container_id" "mkdir -p $container_workflows_dir" false; then
            log ERROR "Failed to create workflows directory in container"
            export_failed=true
        elif ! dockExec "$container_id" "n8n export:workflow --all --separate --output=$container_workflows_dir/" false; then 
            # Check if the error is due to no workflows existing
            if docker exec "$container_id" n8n list workflows 2>&1 | grep -q "No workflows found"; then
                log INFO "No workflows found to backup - this is a clean installation"
                no_data_found=true
            else
                log ERROR "Failed to export individual workflow files"
                export_failed=true
            fi
        fi
    elif [[ $workflows == 1 ]]; then
        log INFO "Exporting workflows as single file for local storage..."
        if ! dockExec "$container_id" "n8n export:workflow --all --output=$container_workflows" false; then 
            # Check if the error is due to no workflows existing
            if docker exec "$container_id" n8n list workflows 2>&1 | grep -q "No workflows found"; then
                log INFO "No workflows found to backup - this is a clean installation"
                no_data_found=true
            else
                log ERROR "Failed to export workflows"
                export_failed=true
            fi
        fi
    else
        log INFO "Workflows backup disabled - skipping workflow export"
    fi

    # Export credentials based on storage mode and folder structure requirements
    local need_decrypted_credentials=false
    if [[ "$folder_structure_enabled" == true ]]; then
        need_decrypted_credentials=true
    fi
    if [[ "${credentials_encrypted:-true}" == "false" ]]; then
        need_decrypted_credentials=true
    fi

    local decrypted_export_done=false
    local credentials_available=true

    if [[ $credentials != 0 || $need_decrypted_credentials == true ]]; then
        if $need_decrypted_credentials; then
            local decrypted_cmd="n8n export:credentials --all --decrypted --output=$container_credentials_decrypted"
            if [[ "${credentials_encrypted:-true}" == "false" ]]; then
                log INFO "Exporting credentials in decrypted form (per configuration)..."
            else
                log DEBUG "Exporting temporary decrypted credentials for folder structure authentication..."
            fi

            if ! dockExec "$container_id" "$decrypted_cmd" false; then
                local credentials_list_output
                credentials_list_output=$(docker exec "$container_id" n8n list credentials 2>&1 || true)
                if printf '%s' "$credentials_list_output" | grep -q "No credentials found"; then
                    log INFO "No credentials found to backup - this is a clean installation"
                    no_data_found=true
                    credentials_available=false
                else
                    log ERROR "Failed to export decrypted credentials"
                    export_failed=true
                fi
            else
                decrypted_export_done=true
                log DEBUG "Decrypted credentials export stored at $container_credentials_decrypted"
            fi
        fi

        if [[ $credentials != 0 && "${credentials_encrypted:-true}" != "false" && $credentials_available == true ]]; then
            log INFO "Exporting credentials for $credentials_desc storage..."
            log DEBUG "Exporting credentials in encrypted form (default)"
            local cred_export_cmd="n8n export:credentials --all --output=$container_credentials_encrypted"
            if ! dockExec "$container_id" "$cred_export_cmd" false; then
                local credentials_list_output
                credentials_list_output=$(docker exec "$container_id" n8n list credentials 2>&1 || true)
                if printf '%s' "$credentials_list_output" | grep -q "No credentials found"; then
                    log INFO "No credentials found to backup - this is a clean installation"
                    no_data_found=true
                    credentials_available=false
                else
                    log ERROR "Failed to export credentials"
                    export_failed=true
                fi
            fi
        fi
    else
        log INFO "Credentials backup disabled - skipping credentials export"
    fi

    if $export_failed; then
        log ERROR "Failed to export data from n8n"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Handle environment variables (will be stored locally only - NOT pushed to Git)
    log INFO "Capturing environment variables for local storage only (NOT pushed to Git)..."
    if ! dockExec "$container_id" "printenv | grep ^N8N_ > $container_env" false; then
        log WARN "Could not capture N8N_ environment variables from container."
    fi

    # --- Process Local Storage ---
    log HEADER "Storing Data Locally"
    
    # Handle workflows locally if requested
    if [[ $workflows == 1 ]] && docker exec "$container_id" sh -c "[ -f '$container_workflows' ]"; then
        log INFO "Saving workflows to local storage..."
        if $is_dry_run; then
            log DRYRUN "Would copy workflows from container to local storage: $local_workflows_file"
            log DRYRUN "Would set permissions 600 on workflows file"
        else
            # Archive existing workflows only if NOT using timestamped directories
            # (timestamped directories naturally separate backups)
            if [[ "$use_dated_backup" != "true" ]] && [ -f "$local_workflows_file" ]; then
                log INFO "Archiving existing workflows before backup..."
                if ! archive_workflows "$local_workflows_file" "$base_backup_dir" "$is_dry_run" "$local_rotation_limit"; then
                    log WARN "Failed to archive existing workflows, but continuing..."
                fi
            fi

            # Copy new workflows from container to local storage
            if docker cp "${container_id}:${container_workflows}" "$local_workflows_file"; then
                if ! prettify_json_file "$local_workflows_file" "$is_dry_run"; then
                    log WARN "Failed to prettify local workflows JSON"
                fi
                chmod 600 "$local_workflows_file" || log WARN "Could not set permissions on workflows file"
                log SUCCESS "Workflows stored securely in local storage: $local_workflows_file"
            else
                log ERROR "Failed to copy workflows to local storage"
                rm -rf "$tmp_dir"
                return 1
            fi
        fi
    elif [[ $workflows == 1 ]]; then
        log INFO "No workflows file found in container"
        if $no_data_found; then
            if ! $is_dry_run; then
                echo "[]" > "$local_workflows_file"
                chmod 600 "$local_workflows_file"
                log INFO "Created empty workflows file in local storage"
            else
                log DRYRUN "Would create empty workflows file in local storage"
            fi
        fi
    fi
    
    # Handle credentials locally  
    if [[ $credentials == 1 ]] && docker exec "$container_id" sh -c "[ -f '$container_credentials_backup_path' ]"; then
        log INFO "Saving credentials to local secure storage..."
        if $is_dry_run; then
            log DRYRUN "Would copy credentials from container to local storage: $local_credentials_file"
            log DRYRUN "Would set permissions 600 on credentials file"
        else
            # Archive existing credentials only if NOT using timestamped directories
            if [[ "$use_dated_backup" != "true" ]] && [ -f "$local_credentials_file" ]; then
                log INFO "Archiving existing credentials before backup..."
                if ! archive_credentials "$local_credentials_file" "$base_backup_dir" "$is_dry_run" "$local_rotation_limit"; then
                    log WARN "Failed to archive existing credentials, but continuing..."
                fi
            fi

            # Copy new credentials from container to local storage
            if docker cp "${container_id}:${container_credentials_backup_path}" "$local_credentials_file"; then
                if ! prettify_json_file "$local_credentials_file" "$is_dry_run"; then
                    log WARN "Failed to prettify local credentials JSON"
                fi
                chmod 600 "$local_credentials_file" || log WARN "Could not set permissions on credentials file"
                log SUCCESS "Credentials stored securely in local storage: $local_credentials_file"
            else
                log ERROR "Failed to copy credentials to local storage"
                rm -rf "$tmp_dir"
                return 1
            fi
        fi
    elif [[ $credentials == 1 ]]; then
        log INFO "No credentials file found in container"
        if $no_data_found; then
            if ! $is_dry_run; then
                echo "{}" > "$local_credentials_file"
                chmod 600 "$local_credentials_file"
                log INFO "Created empty credentials file in local storage"
            else
                log DRYRUN "Would create empty credentials file in local storage"
            fi
        fi
    fi
    
    # Store .env file in local storage (always local for security)
    if docker exec "$container_id" sh -c "[ -f '$container_env' ]"; then
        log INFO "Backing up environment variables..."
        if $is_dry_run; then
            log DRYRUN "Would copy .env from container to local storage: $local_env_file"
            log DRYRUN "Would set permissions 600 on .env file"
        else
            if docker cp "${container_id}:${container_env}" "$local_env_file"; then
                chmod 600 "$local_env_file" || log WARN "Could not set permissions on .env file"
                log SUCCESS ".env file stored securely in local storage: $local_env_file"
            else
                log WARN "Failed to copy .env file to local storage"
            fi
        fi
    else
        log INFO "No .env file found in container"
    fi

    log SUCCESS "Local backup operations completed successfully"
    
    # --- Git Repository Backup (Conditional) ---
    if [[ $workflows == 2 ]] || [[ $credentials == 2 ]]; then
        local tmp_dir="/tmp/n8n-backup-git-$$"
        if $is_dry_run; then
            log DRYRUN "Would create temporary Git directory: $tmp_dir"
        else
            mkdir -p "$tmp_dir"
            cd "$tmp_dir" || {
                log ERROR "Failed to create temporary Git directory"
                return 1
            }
        fi

        # Clone or initialize repository
        log INFO "Initializing Git repository for remote backup..."
        if $is_dry_run; then
            log DRYRUN "Would clone repository: $github_repo (branch: $branch)"
        else
            local clone_url="https://${github_token}@github.com/${github_repo}.git"
            if git clone --depth 1 -b "$branch" "$clone_url" . 2>/dev/null; then
                log SUCCESS "Repository cloned successfully"
            else
                log WARN "Branch '$branch' not found, creating new repository"
                git init .
                git remote add origin "$clone_url"
                local fallback_email="${git_commit_email:-n8n-backup-script@localhost}"
                local fallback_name="${git_commit_name:-n8n-backup-script}"
                git config user.email "$fallback_email"
                git config user.name "$fallback_name"
            fi
        fi

        # Determine target directory structure
        local target_dir="$tmp_dir"
        if [[ $use_dated_backup == true ]]; then
            target_dir="$tmp_dir/$backup_timestamp"
            if ! $is_dry_run; then
                mkdir -p "$target_dir"
            else
                log DRYRUN "Would create dated backup directory: $target_dir"
            fi
        fi

        # Copy files to Git repository
    local copy_status="success"
    local folder_structure_committed=false
        
        # Handle workflows for remote storage
        if [[ $workflows == 2 ]]; then
            log INFO "Preparing workflows for Git repository..."
            if [[ "$folder_structure_enabled" == true ]]; then
                if $is_dry_run; then
                    log DRYRUN "Would create n8n folder structure in Git repository"
                else
                    log DEBUG "Creating n8n folder structure using API..."
                    log DEBUG "n8n URL: $n8n_base_url"
                    export container_id="$container_id"
                    if create_folder_structure_with_git "$container_id" "$target_dir" "$tmp_dir" "$is_dry_run" "$container_credentials_decrypted"; then
                        folder_structure_committed=true
                        log SUCCESS "n8n folder structure created in repository with individual commits"
                    else
                        log ERROR "Failed to create folder structure, attempting flat structure fallback"
                    fi
                fi
            fi

            if ! $folder_structure_committed; then
                if $is_dry_run; then
                    log DRYRUN "Would copy workflows to Git repository: $target_dir/workflows.json"
                else
                    if docker exec "$container_id" sh -c "[ -f '$container_workflows' ]"; then
                        if docker cp "${container_id}:${container_workflows}" "$target_dir/workflows.json"; then
                            if ! prettify_json_file "$target_dir/workflows.json" "$is_dry_run"; then
                                log WARN "Failed to prettify workflows JSON in Git repository"
                            fi
                            log SUCCESS "Workflows copied to Git repository"
                        else
                            log ERROR "Failed to copy workflows to Git repository"
                            copy_status="failed"
                        fi
                    elif docker exec "$container_id" sh -c "[ -d '$container_workflows_dir' ]"; then
                        if docker cp "${container_id}:${container_workflows_dir}/." "$target_dir/"; then
                            prettify_json_tree "$target_dir" "$is_dry_run" || log WARN "Completed workflow JSON prettify with warnings in Git repository"
                            log SUCCESS "Workflows copied to Git repository from directory export"
                        else
                            log ERROR "Failed to copy workflow directory to Git repository"
                            copy_status="failed"
                        fi
                    else
                        log ERROR "No workflow export found in container for flat structure backup"
                        copy_status="failed"
                    fi
                fi
            fi
        fi

        # Handle credentials for remote storage
    if [[ $credentials == 2 ]] && docker exec "$container_id" sh -c "[ -f '$container_credentials_backup_path' ]"; then
            if [[ "${credentials_encrypted:-true}" == "false" ]]; then
                log WARN "⚠️  Storing decrypted credentials in Git repository (high risk)."
            else
                log INFO "🔐 Storing encrypted credentials in Git repository."
            fi
            if $is_dry_run; then
                log DRYRUN "Would copy credentials to Git repository: $target_dir/credentials.json"
            else
                if docker cp "${container_id}:${container_credentials_backup_path}" "$target_dir/credentials.json"; then
                    if ! prettify_json_file "$target_dir/credentials.json" "$is_dry_run"; then
                        log WARN "Failed to prettify credentials JSON in Git repository"
                    fi
                    log SUCCESS "Credentials copied to Git repository"
                else
                    log ERROR "Failed to copy credentials to Git repository"
                    copy_status="failed"
                fi
            fi
        fi

        # Create .gitignore based on what's included
        local gitignore_file="$tmp_dir/.gitignore"
        if $is_dry_run; then
            log DRYRUN "Would create .gitignore file"
        else
            local template_dir="$(dirname "${BASH_SOURCE[0]}")/../templates"
            local gitignore_base_template="$template_dir/gitignore.base"
            local gitignore_credentials_template="$template_dir/gitignore.credentials-secure"

            if [[ -f "$gitignore_base_template" ]]; then
                if ! cp "$gitignore_base_template" "$gitignore_file"; then
                    log ERROR "Failed to copy gitignore base template to $gitignore_file"
                    rm -f "$gitignore_file"
                    return 1
                fi
            else
                log WARN "Gitignore base template missing ($gitignore_base_template). Using fallback defaults."
                cat > "$gitignore_file" << 'EOF'
# n8n Git Backup - managed ignore rules
.gitignore

# Environment security
.env
*.env
**/.env
**/*.env

# Archive directories
archive/

# OS and editor files
.DS_Store
Thumbs.db
*.swp
*.swo
*~

# Temporary files
*.tmp
*.temp
EOF
            fi

            if [[ $credentials == 2 ]]; then
                log SUCCESS "Created .gitignore for credential-inclusive backup"
            else
                if [[ -f "$gitignore_credentials_template" ]]; then
                    cat "$gitignore_credentials_template" >> "$gitignore_file"
                else
                    log WARN "Gitignore credentials template missing ($gitignore_credentials_template). Using fallback defaults."
                    cat >> "$gitignore_file" << 'EOF'
# Sensitive credentials (excluded from repository)
credentials.json
**/credentials.json
EOF
                fi
                log SUCCESS "Created .gitignore to prevent sensitive data from being committed"
            fi
        fi

        # Check if workflow copy operations failed
        if [ "$copy_status" = "failed" ]; then 
            log ERROR "File copy operations failed, aborting backup"
            rm -rf "$tmp_dir"
            return 1
        fi
        log INFO "Cleaning up temporary files in container..."
        dockExec "$container_id" "rm -f $container_workflows $container_credentials_encrypted $container_credentials_decrypted $container_env" "$is_dry_run" || log WARN "Could not clean up temporary files in container."

        # Git Commit and Push
        if [[ $credentials == 2 ]]; then
            log HEADER "Committing Workflows and Credentials to Git"
        else
            log HEADER "Committing Workflows to Git (Credentials Excluded)"
        fi
        log INFO "Adding files to Git repository..."
        
        if $is_dry_run; then
            log DRYRUN "Would add workflow folder structure and files to Git index"
            if [[ $credentials == 2 ]]; then
                log DRYRUN "Would also add credentials file to Git index"
            fi
        else
            # Change to the git directory
            cd "$tmp_dir" || { 
                log ERROR "Failed to change to git directory for add operation"; 
                rm -rf "$tmp_dir"; 
                return 1; 
            }
            
            # Debug: Show what files exist in the target directory
            log DEBUG "Files in target directory before Git add:"
            find . -type f | head -20 | while read -r file; do
                log DEBUG "  Found: $file"
            done
            
            # NOTE: .gitignore is created but NOT added to Git repository
            # This prevents sensitive data from being committed while keeping .gitignore local only
            
            if [[ $use_dated_backup == true ]]; then
                # For dated backups, add the entire backup subdirectory with folder structure
                if [ -d "$backup_timestamp" ]; then
                    log DEBUG "Adding dated backup directory with folder structure: $backup_timestamp"
                    
                    if ! git add "$backup_timestamp"; then
                        log ERROR "Git add failed for dated backup directory"
                        cd - > /dev/null || true
                        rm -rf "$tmp_dir"
                        return 1
                    fi
                else
                    log WARN "Backup directory not found: $backup_timestamp (may be empty)"
                fi
            else
                # Standard repo-root backup - add workflow files and folders specifically
                if [[ $workflows == 2 && $folder_structure_committed == false ]]; then
                    log DEBUG "Adding workflow folder structure to repository root"
                    
                    # Add workflow folders and JSON files specifically
                    local files_added=0
                    # Find all workflow JSON files and add them
                    find . -name "*.json" -type f | while read -r json_file; do
                        if [[ "$json_file" != "./credentials.json" ]]; then
                            log DEBUG "Adding workflow file: $json_file"
                            git add "$json_file"
                            files_added=$((files_added + 1))
                        fi
                    done
                    
                    # Also add any directories that were created
                    find . -type d -not -path "./.git*" -not -path "." | while read -r dir; do
                        log DEBUG "Adding directory: $dir"
                        git add "$dir/.gitkeep" 2>/dev/null || true  # Add .gitkeep if it exists
                    done
                    
                    log DEBUG "Git status before commit:"
                    git status --short
                fi
                
                # Handle credentials separately if needed
                if [[ $credentials == 2 ]] && [ -f "credentials.json" ]; then
                    log DEBUG "Adding credentials file to Git"
                    if ! git add credentials.json; then
                        log ERROR "Git add failed for credentials file"
                        cd - > /dev/null || true
                        rm -rf "$tmp_dir"
                        return 1
                    fi
                fi
            fi
            
            # Success message
            if [[ $folder_structure_committed == true && $credentials == 2 ]]; then
                log SUCCESS "Workflow folder structure and credentials processed successfully"
            elif [[ $folder_structure_committed == true ]]; then
                log SUCCESS "Workflow folder structure processed successfully"
            elif [[ $workflows == 2 && $credentials == 2 ]]; then
                log SUCCESS "Workflow folder structure and credentials added to Git successfully"
            elif [[ $workflows == 2 ]]; then
                log SUCCESS "Workflow folder structure added to Git successfully (credentials excluded)"
            else
                log SUCCESS "Files added to Git successfully"
            fi
            
            # Verify that files were staged correctly
            log DEBUG "Git staging status:"
            git status --short || true
        fi

        # Generate smart commit message
        local commit_msg
        if [[ $workflows == 2 ]]; then
            local workflow_changes
            workflow_changes=$(generate_workflow_commit_message "$target_dir" "$is_dry_run")
            if [[ $credentials == 2 ]]; then
                commit_msg="$workflow_changes + credentials"
            else
                commit_msg="$workflow_changes"
            fi
        else
            # Only credentials in Git (unlikely but possible)
            commit_msg="Credentials backup - $(date +"%Y-%m-%d_%H-%M-%S")"
        fi
        
        # Add n8n version and backup info
        local n8n_ver
        n8n_ver=$(docker exec "$container_id" n8n --version 2>/dev/null | grep -o 'n8n@[0-9.]*' | cut -d'@' -f2 || echo "unknown")
        commit_msg="$commit_msg (n8n v$n8n_ver)"
        
        if [[ $use_dated_backup == true ]]; then
            commit_msg="$commit_msg [$backup_timestamp]"
        fi
        
        # Ensure git identity is configured
        if $is_dry_run; then
            log DRYRUN "Would configure Git identity if needed"
            log DRYRUN "Would commit with message: $commit_msg"
        else
            if [[ -z "$(git config user.email 2>/dev/null)" ]]; then
                local configured_email="${git_commit_email:-n8n-backup-script@localhost}"
                log WARN "No Git user.email configured, setting default to $configured_email"
                git config user.email "$configured_email" || true
            fi
            if [[ -z "$(git config user.name 2>/dev/null)" ]]; then
                local configured_name="${git_commit_name:-n8n-backup-script}"
                log WARN "No Git user.name configured, setting default to $configured_name"
                git config user.name "$configured_name" || true
            fi
            
            if $folder_structure_committed; then
                log INFO "Pushing workflow commits to remote repository..."
                if git push origin "$branch"; then
                    log SUCCESS "✅ Backup pushed to GitHub repository successfully!"
                else
                    log ERROR "Failed to push workflow commits to remote repository"
                    rm -rf "$tmp_dir"
                    return 1
                fi
            else
                # Commit changes
                if git diff --cached --quiet; then
                    log WARN "No changes detected in Git repository - nothing to commit"
                else
                    if git commit -m "$commit_msg"; then
                        log SUCCESS "Changes committed successfully"
                        
                        # Push to remote repository
                        log INFO "Pushing changes to remote repository..."
                        if git push origin "$branch"; then
                            log SUCCESS "✅ Backup pushed to GitHub repository successfully!"
                        else
                            log ERROR "Failed to push changes to remote repository"
                            rm -rf "$tmp_dir"
                            return 1
                        fi
                    else
                        log ERROR "Failed to commit changes"
                        rm -rf "$tmp_dir"
                        return 1
                    fi
                fi
            fi
        fi

        # Cleanup
        cd - > /dev/null || true
        rm -rf "$tmp_dir"
        log INFO "Git temporary directory cleaned up"
    fi

    # --- Final Summary ---
    log HEADER "Backup Summary"
    
    if [[ $workflows == 2 && $credentials == 2 ]]; then
    log SUCCESS "✅ Complete backup successful!"
    log SUCCESS "📄 Workflows: Stored in GitHub repository with folder structure"
    log SUCCESS "🔒 Credentials: Stored in GitHub repository (less secure)"
    elif [[ $workflows == 2 && $credentials == 1 ]]; then
    log SUCCESS "✅ Hybrid backup successful!"
    log SUCCESS "📄 Workflows: Stored in GitHub repository with folder structure"
    log SUCCESS "🔒 Credentials: Stored securely in local storage ($local_credentials_file)"
    elif [[ $workflows == 1 && $credentials == 1 ]]; then
    log SUCCESS "✅ Local backup successful!"
    log SUCCESS "📄 Workflows: Stored securely in local storage ($local_workflows_file)"
    log SUCCESS "🔒 Credentials: Stored securely in local storage ($local_credentials_file)"
    elif [[ $workflows == 1 && $credentials == 2 ]]; then
    log SUCCESS "✅ Mixed backup successful!"
    log SUCCESS "📄 Workflows: Stored securely in local storage ($local_workflows_file)"
    log SUCCESS "🔒 Credentials: Stored in GitHub repository (less secure)"
    fi
    
    log SUCCESS "🌱 Environment: Stored securely in local storage ($local_env_file)"
    
    if [ "$use_dated_backup" = "true" ]; then
        log INFO "📅 Dated backup created: $backup_timestamp"
    fi
    
    # Display rotation information for local backups
    if [[ $workflows == 1 ]] || [[ $credentials == 1 ]]; then
        if [[ "$local_rotation_limit" == "0" ]]; then
            log INFO "🔄 Rotation: Disabled (current backup overwrites previous)"
        elif [[ "$local_rotation_limit" == "unlimited" ]]; then
            log INFO "🔄 Rotation: Unlimited (all backups preserved)"
        else
            log INFO "🔄 Rotation: Keep $local_rotation_limit most recent backups"
        fi
    fi
    
    return 0
}
