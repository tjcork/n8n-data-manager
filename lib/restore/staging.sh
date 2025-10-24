#!/usr/bin/env bash
# Simplified workflow staging for restore - creates manifest from directory structure

# Generate manifest from directory structure
# Args: source_dir, output_manifest_path
# Returns: 0 on success, 1 on failure
generate_workflow_manifest() {
    local source_dir="$1"
    local output_manifest_path="$2"
    
    if [[ -z "$source_dir" || ! -d "$source_dir" ]]; then
        log ERROR "Invalid source directory for manifest generation: ${source_dir:-<empty>}"
        return 1
    fi
    
    if [[ -z "$output_manifest_path" ]]; then
        log ERROR "Output manifest path required"
        return 1
    fi
    
    # Clear/create output file
    : > "$output_manifest_path"
    
    local workflow_count=0
    
    # Find all workflow JSON files
    while IFS= read -r -d '' workflow_file; do
        # Read workflow JSON
        local workflow_json
        if ! workflow_json=$(cat "$workflow_file" 2>/dev/null); then
            log WARN "Failed to read workflow file: $workflow_file"
            continue
        fi
        
        # Validate JSON
        if ! printf '%s' "$workflow_json" | jq empty 2>/dev/null; then
            log WARN "Invalid JSON in workflow file: $workflow_file"
            continue
        fi
        
        # Extract basic fields
        local workflow_id workflow_name
        workflow_id=$(printf '%s' "$workflow_json" | jq -r '.id // ""' 2>/dev/null)
        workflow_name=$(printf '%s' "$workflow_json" | jq -r '.name // ""' 2>/dev/null)
        
        # Compute relative path from source_dir
    local relative_path="${workflow_file#"${source_dir}/"}"
        
        # Create manifest entry (simple NDJSON)
        local manifest_entry
        manifest_entry=$(jq -n \
            --arg id "$workflow_id" \
            --arg name "$workflow_name" \
            --arg path "$relative_path" \
            '{
                id: $id,
                name: $name,
                storagePath: $path
            }')
        
        printf '%s\n' "$manifest_entry" >> "$output_manifest_path"
        workflow_count=$((workflow_count + 1))
        
    done < <(find "$source_dir" -type f -name "*.json" -print0 2>/dev/null)
    
    log INFO "Generated manifest with $workflow_count workflow(s)"
    
    if [[ "$workflow_count" -eq 0 ]]; then
        log WARN "No workflows found in $source_dir"
        return 1
    fi
    
    return 0
}

sanitize_log_value() {
    printf '%s' "$1" | tr -d '\r' | tr '\n' ' ' | sed 's/[[:cntrl:]]//g'
}

# Update manifest with post-import workflow IDs
# This reconciles the manifest after import to track what IDs were actually assigned
# Args: manifest_path, post_import_snapshot, output_path
# Returns: 0 on success
reconcile_manifest_ids() {
    local manifest_path="$1"
    local post_import_snapshot="$2"
    local output_path="$3"
    
    if [[ -z "$manifest_path" || ! -f "$manifest_path" ]]; then
        log ERROR "Manifest file required for reconciliation"
        return 1
    fi
    
    if [[ -z "$post_import_snapshot" || ! -f "$post_import_snapshot" ]]; then
        log ERROR "Post-import snapshot required for reconciliation"
        return 1
    fi
    
    # Build lookup: workflow by name (for newly created workflows without stable IDs)
    declare -A workflow_by_name=()
    
    while IFS=$'\t' read -r wf_id wf_name _; do
        [[ -z "$wf_id" ]] && continue
        
        local name_key
        name_key=$(printf '%s' "$wf_name" | tr '[:upper:]' '[:lower:]')
        
        # Store last seen ID for this name (handles duplicates)
        workflow_by_name["$name_key"]="$wf_id"
        
    done < <(printf '%s' "$(cat "$post_import_snapshot")" | jq -r '
        (if type == "array" then . else (.data // []) end)
        | .[]
        | [.id, .name, (.meta.instanceId // "")] 
        | @tsv
    ' 2>/dev/null | tr -d '\r')
    
    # Update manifest entries
    : > "$output_path"
    
    local reconciled=0
    local unreconciled=0
    
    while IFS= read -r manifest_line; do
        [[ -z "$manifest_line" ]] && continue
        
        local manifest_id manifest_name
        manifest_id=$(printf '%s' "$manifest_line" | jq -r '.id // ""' 2>/dev/null)
        manifest_name=$(printf '%s' "$manifest_line" | jq -r '.name // ""' 2>/dev/null)
        
        # Try to find actual imported ID
        local actual_id=""
        
        # Strategy 1: ID from manifest still exists
        if [[ -n "$manifest_id" ]]; then
            if printf '%s' "$(cat "$post_import_snapshot")" | jq -e --arg id "$manifest_id" '
                (if type == "array" then . else (.data // []) end)
                | any(.id == $id)
            ' >/dev/null 2>&1; then
                actual_id="$manifest_id"
            fi
        fi
        
        # Strategy 2: Match by name
        if [[ -z "$actual_id" && -n "$manifest_name" ]]; then
            local name_key
            name_key=$(printf '%s' "$manifest_name" | tr '[:upper:]' '[:lower:]')
            actual_id="${workflow_by_name[$name_key]:-}"
        fi
        
        # Update manifest entry with reconciliation info
        local updated_entry
        if [[ -n "$actual_id" ]]; then
            updated_entry=$(printf '%s' "$manifest_line" | jq \
                --arg actualId "$actual_id" \
                '. + {actualImportedId: $actualId, idReconciled: true}')
            reconciled=$((reconciled + 1))
        else
            updated_entry=$(printf '%s' "$manifest_line" | jq \
                '. + {idReconciled: false, idReconciliationWarning: "workflow not found after import"}')
            unreconciled=$((unreconciled + 1))
        fi
        
        printf '%s\n' "$updated_entry" >> "$output_path"
        
    done < "$manifest_path"
    
    log INFO "Manifest reconciliation: $reconciled resolved, $unreconciled unresolved"
    
    return 0
}

# Validate workflow ID format (must be exactly 16 alphanumeric characters or empty)
# Args: workflow_id
# Returns: 0 if valid, 1 if invalid
is_valid_workflow_id() {
    local workflow_id="$1"
    
    # Empty is valid (will be assigned by n8n)
    [[ -z "$workflow_id" ]] && return 0
    
    # Must be exactly 16 alphanumeric characters
    if [[ "$workflow_id" =~ ^[A-Za-z0-9]{16}$ ]]; then
        return 0
    fi
    
    return 1
}

# Snapshot existing workflows from n8n instance
# Args: container_id, container_credentials_path (optional), keep_session_alive
# Returns: 0 on success, sets SNAPSHOT_EXISTING_WORKFLOWS_PATH
# Global: Sets existing_workflow_snapshot_source to "api" or "container"
snapshot_existing_workflows() {
    local container_id="$1"
    local container_credentials_path="${2:-}"
    local keep_session_alive="${3:-false}"
    local snapshot_path=""
    # shellcheck disable=SC2034 # Expose snapshot path to other restore modules
    SNAPSHOT_EXISTING_WORKFLOWS_PATH=""
    local session_initialized=false

    # Try API method first if n8n base URL is configured
    if [[ -n "${n8n_base_url:-}" ]]; then
        if prepare_n8n_api_auth "$container_id" "$container_credentials_path"; then
            session_initialized=true
            local api_payload
            if api_payload=$(n8n_api_get_workflows); then
                local normalized_tmp
                normalized_tmp=$(mktemp -t n8n-existing-workflows-XXXXXXXX.json)
                # Normalize to array format for compatibility with reconciliation logic
                if printf '%s' "$api_payload" | jq -c 'if type == "array" then . else (.data // []) end' > "$normalized_tmp" 2>/dev/null; then
                    snapshot_path="$normalized_tmp"
                    export existing_workflow_snapshot_source="api"
                else
                    rm -f "$normalized_tmp"
                    log WARN "Unable to normalize workflow list from n8n API; falling back to CLI export."
                fi
            else
                log WARN "Failed to retrieve workflow list via n8n API; attempting CLI export fallback."
            fi
            
            # Cleanup session if not needed
            if [[ "$session_initialized" == "true" && "$keep_session_alive" != "true" ]]; then
                finalize_n8n_api_auth
                session_initialized=false
            fi
        else
            log DEBUG "n8n API authentication unavailable; attempting CLI export fallback."
        fi
    fi

    # Fallback to CLI export if API method didn't work
    if [[ -z "$snapshot_path" && -n "$container_id" ]]; then
        log DEBUG "Attempting CLI workflow snapshot"
        local container_tmp="/tmp/n8n-existing-workflows-$$.json"
        if dockExec "$container_id" "n8n export:workflow --all --output=$container_tmp" false; then
            local host_tmp
            host_tmp=$(mktemp -t n8n-existing-workflows-XXXXXXXX.json)
            if docker cp "${container_id}:${container_tmp}" "$host_tmp" >/dev/null 2>&1; then
                snapshot_path="$host_tmp"
                export existing_workflow_snapshot_source="container"
                log DEBUG "Captured workflow snapshot via CLI export"
            else
                rm -f "$host_tmp"
                log WARN "Unable to copy workflow snapshot from container; duplicate detection may be limited."
            fi
            dockExec "$container_id" "rm -f $container_tmp" false || true
        else
            log WARN "Failed to export workflows from container; proceeding without snapshot."
        fi
    fi

    # Set result
    if [[ -n "$snapshot_path" ]]; then
        SNAPSHOT_EXISTING_WORKFLOWS_PATH="$snapshot_path"
        return 0
    fi

    log INFO "Workflow snapshot unavailable; proceeding without pre-import existence checks."
    
    # Final session cleanup
    if [[ "$session_initialized" == "true" && "$keep_session_alive" != "true" ]]; then
        finalize_n8n_api_auth
    elif [[ "$session_initialized" == "true" && "$keep_session_alive" == "true" ]]; then
        # shellcheck disable=SC2034 # Ensure global snapshot state reflects active session reuse
        SNAPSHOT_EXISTING_WORKFLOWS_PATH=""
    fi
    
    return 1
}

# Stage workflow directory to container with ID sanitization and conflict resolution
# This is the main entry point for workflow staging during restore operations
# 
# Args:
#   $1 source_dir - Local directory containing workflow JSON files
#   $2 container_id - Docker container ID
#   $3 container_target_dir - Path in container where files will be copied
#   $4 output_manifest_path - Where to write the staging manifest
#   $5 existing_snapshot_path - Path to pre-import workflow snapshot (optional)
#   $6 preserve_ids - "true" to keep original IDs when possible, "false" to always reassign
#   $7 no_overwrite - "true" to always generate new IDs, "false" to allow ID reuse
#   $8 workflow_mapping_path - Path to workflow-folder mapping JSON (optional)
#
# Returns: 0 on success, 1 on failure
#
# ID Handling Logic:
# 1. If preserve_ids=false → check for existing workflow with same name in target folder (PRIORITY)
#    - If match found → use existing workflow's ID (enables update instead of duplicate)
# 2. If ID is not 16 alphanumeric chars → remove ID (n8n will assign new)
# 3. If no_overwrite=true → always remove ID (force new workflow creation)
# 4. If ID conflicts with different workflow name → remove ID (prevent wrong workflow update)
# 5. If preserve_ids=true → keep original ID (unless conflicts detected in step 4)
stage_directory_workflows_to_container() {
    local source_dir="$1"
    local container_id="$2"
    local container_target_dir="$3"
    local output_manifest_path="$4"
    local existing_snapshot_path="${5:-}"
    local preserve_ids="${6:-false}"
    local no_overwrite="${7:-false}"
    local workflow_mapping_path="${8:-}"
    local target_folder="${9:-}"
    
    if [[ -z "$source_dir" || ! -d "$source_dir" ]]; then
        log ERROR "Invalid source directory: ${source_dir:-<empty>}"
        return 1
    fi
    
    if [[ -z "$container_id" ]]; then
        log ERROR "Container ID required for staging"
        return 1
    fi
    
    log DEBUG "Staging workflows from $source_dir to container $container_id"
    log DEBUG "ID handling: preserve_ids=$preserve_ids, no_overwrite=$no_overwrite"
    [[ -n "$target_folder" ]] && log DEBUG "Target folder for matching: $target_folder"
    
    # Create temp staging directory
    local staging_dir
    staging_dir=$(mktemp -d -t n8n-staging-XXXXXXXX)
    
    # Build existing workflow lookup
    declare -A existing_workflows_by_id=()
    declare -A existing_workflows_by_name=()
    declare -A existing_workflows_by_name_and_folder=()
    declare -A staged_workflows_by_id=()  # Track IDs in current import batch
    
    # Load folder assignments from workflow mapping if available
    declare -A workflow_folder_assignments=()  # workflow_id -> folder_path
    if [[ -n "$workflow_mapping_path" && -f "$workflow_mapping_path" ]]; then
        log DEBUG "Reading workflow-folder paths from mapping file: $workflow_mapping_path"
        local wf_count
        wf_count=$(jq -r '.workflows | length' "$workflow_mapping_path" 2>/dev/null || echo "0")
        log DEBUG "Mapping file lists $wf_count workflow record(s)"
        
        while IFS=$'\t' read -r wf_id folder_path_raw; do
            [[ -z "$wf_id" ]] && continue
            # Normalize folder path using mapping metadata
            local folder_path
            folder_path=$(printf '%s' "$folder_path_raw" | tr -d '\r\n')
            if [[ "$folder_path" == "Folder" ]]; then
                folder_path=""
            fi
            folder_path=$(printf '%s' "$folder_path" | sed 's:^/*::;s:/*$::')
            workflow_folder_assignments["$wf_id"]="$folder_path"
        done < <(jq -r '
            .workflows[]? |
            select(.id) |
            [
                .id,
                (if (.folders // []) | length > 0 then
                    (.folders | map(.name // "") | join("/"))
                 elif (.displayPath // "") != "" then
                    (.displayPath
                        | (split("/") | if length > 1 then (.[1:] | join("/")) else "" end)
                        | gsub("^Folder/?"; ""))
                 else
                    ""
                 end)
            ] |
            @tsv
        ' "$workflow_mapping_path" 2>/dev/null | tr -d '\r')
        if [[ "${verbose:-false}" == "true" ]]; then
            log DEBUG "Workflow-folder paths available for ${#workflow_folder_assignments[@]} workflow(s)"
        fi
    fi
    
    if [[ -n "$existing_snapshot_path" && -f "$existing_snapshot_path" ]]; then
        log DEBUG "Building existing workflow index from snapshot"
        
        while IFS=$'\t' read -r wf_id wf_name wf_folder_path; do
            [[ -z "$wf_id" ]] && continue
            
            # Index by ID
            existing_workflows_by_id["$wf_id"]="$wf_name"

            # Index by name (case sensitive) when unique
            if [[ -z "${existing_workflows_by_name[$wf_name]:-}" ]]; then
                existing_workflows_by_name["$wf_name"]="$wf_id"
            else
                existing_workflows_by_name["$wf_name"]="__multiple__"
            fi
            
            # Use folder path from mapping file if available, otherwise from snapshot
            local mapped_folder="${workflow_folder_assignments[$wf_id]:-}"
            local effective_folder_path="${mapped_folder:-$wf_folder_path}"
            
            # Index by name+folder for scoped conflict detection (CASE SENSITIVE for both folder AND name)
            if [[ -n "$effective_folder_path" ]]; then
                # Keep both folder path AND workflow name case-sensitive
                # Trim slashes from folder path
                local normalized_folder
                normalized_folder=$(printf '%s' "$effective_folder_path" | sed 's:^/*::;s:/*$::')
                local folder_key="${normalized_folder}/${wf_name}"
                existing_workflows_by_name_and_folder["$folder_key"]="$wf_id"
            fi
            
        done < <(printf '%s' "$(cat "$existing_snapshot_path")" | jq -r '
            (if type == "array" then . else (.data // []) end)
            | map(select(.resource != "folder"))
            | .[]
            | [
                .id,
                .name,
                (if .homeProject.path then .homeProject.path elif .parentFolderId then .parentFolderId else "" end)
            ]
            | @tsv
        ' 2>/dev/null | tr -d '\r')
        
        log DEBUG "Existing workflow index prepared for ${#existing_workflows_by_id[@]} workflow(s)"
    fi
    
    # Clear/create output manifest
    : > "$output_manifest_path"
    
    local processed=0
    local ids_reset=0
    local ids_reused=0
    
    # Process each workflow file
    while IFS= read -r -d '' workflow_file; do
        local workflow_json
        if ! workflow_json=$(cat "$workflow_file" 2>/dev/null); then
            log WARN "Failed to read workflow: $workflow_file"
            continue
        fi
        
        # Validate JSON
        if ! printf '%s' "$workflow_json" | jq empty 2>/dev/null; then
            log WARN "Invalid JSON: $workflow_file"
            continue
        fi
        
        # Extract workflow metadata
        local original_id workflow_name
        original_id=$(printf '%s' "$workflow_json" | jq -r '.id // ""' 2>/dev/null)
        workflow_name=$(printf '%s' "$workflow_json" | jq -r '.name // ""' 2>/dev/null)
        workflow_name=$(printf '%s' "$workflow_name" | tr -d '\r\n')
        
        # Compute target folder path from directory structure
    local relative_path="${workflow_file#"${source_dir}/"}"
        local folder_path
        folder_path=$(dirname "$relative_path")
        [[ "$folder_path" == "." ]] && folder_path=""
        
        # Determine final workflow ID based on policy
    local final_id="$original_id"
    local sanitization_note=""
    local matched_existing_id=""
    local match_strategy=""
    local manifest_action="create"
        
        # Step 1: Check for name-based matching FIRST (if preserve_ids=false)
        # This gives priority to existing workflows with matching names in the target folder
        if [[ "$preserve_ids" == "false" ]]; then
            # Construct full folder path for matching (CASE SENSITIVE for both folder AND name)
            local full_folder_path="$folder_path"
            if [[ -n "$target_folder" && -n "$folder_path" ]]; then
                full_folder_path="${target_folder}/${folder_path}"
            elif [[ -n "$target_folder" ]]; then
                full_folder_path="$target_folder"
            fi
            
            # Trim slashes from folder path (keep case)
            local normalized_folder_path
            normalized_folder_path=$(printf '%s' "$full_folder_path" | sed 's:^/*::;s:/*$::')
            
            # Build folder key (CASE SENSITIVE for both folder and workflow name)
            local folder_key="${normalized_folder_path}/${workflow_name}"
            [[ -z "$normalized_folder_path" ]] && folder_key="$workflow_name"
            
            log DEBUG "Searching folder \"$(sanitize_log_value "$normalized_folder_path")\" for name match: \"$(sanitize_log_value "$workflow_name")\""
            if [[ -n "${existing_workflows_by_name_and_folder[$folder_key]:-}" ]]; then
                local existing_id="${existing_workflows_by_name_and_folder[$folder_key]}"
                log DEBUG "Matched existing workflow ID $existing_id for \"$(sanitize_log_value "$workflow_name")\" (ID: \"$(sanitize_log_value "$original_id")\")"
                final_id="$existing_id"
                matched_existing_id="$existing_id"
                match_strategy="name+folder"
                manifest_action="update"
            else
                log DEBUG "No existing workflow named \"$(sanitize_log_value "$workflow_name")\" found in folder \"$(sanitize_log_value "$normalized_folder_path")\""
            fi
        fi

        # Step 1b: If folder scoped lookup failed, try global name match when unique
        if [[ -z "$matched_existing_id" && "$preserve_ids" == "false" ]]; then
            if [[ -n "${existing_workflows_by_name[$workflow_name]:-}" && "${existing_workflows_by_name[$workflow_name]}" != "__multiple__" ]]; then
                local existing_id_global="${existing_workflows_by_name[$workflow_name]}"
                log DEBUG "Matched unique workflow name \"$(sanitize_log_value "$workflow_name")\" globally (ID: $existing_id_global)"
                final_id="$existing_id_global"
                matched_existing_id="$existing_id_global"
                match_strategy="name-only"
                manifest_action="update"
            fi
        fi
        
        # Step 2: Validate ID format (if not already matched by name)
        if [[ -z "$sanitization_note" ]] && ! is_valid_workflow_id "$original_id" && [[ -z "$matched_existing_id" ]]; then
            if [[ -n "$original_id" ]]; then
                sanitization_note="invalid_id_format"
                log DEBUG "Manifest supplied invalid ID \"$(sanitize_log_value "$original_id")\" for \"$(sanitize_log_value "$workflow_name")\" — clearing before import"
            fi
            final_id=""
        fi
        
        # Step 3: Apply no_overwrite policy (always generate new IDs)
        if [[ "$no_overwrite" == "true" && -n "$final_id" && -z "$sanitization_note" ]]; then
            sanitization_note="no_overwrite_policy"
            log DEBUG "Removing existing ID for \"$(sanitize_log_value "$workflow_name")\" due to --no-overwrite flag"
            final_id=""
        fi
        
        # Step 4: Check for ID conflicts (duplicate ID with different name or within batch)
        if [[ -n "$final_id" && -z "$sanitization_note" ]]; then
            # Check existing n8n workflows
            if [[ -n "${existing_workflows_by_id[$final_id]:-}" ]]; then
                local existing_name="${existing_workflows_by_id[$final_id]}"
                
                # ANY ID conflict means we must remove the ID to force creation of a new workflow
                # Otherwise n8n import will UPDATE the existing workflow with that ID
                if [[ "$existing_name" != "$workflow_name" ]]; then
                    sanitization_note="id_conflict_different_workflow"
                    log DEBUG "Manifest ID $final_id for \"$(sanitize_log_value "$workflow_name")\" conflicts with existing workflow \"$(sanitize_log_value "$existing_name")\" — clearing to avoid overwrite"
                    final_id=""
                else
                    # Same name + same ID = legitimate update, allow it
                    log DEBUG "Manifest ID $final_id confirms update-in-place for \"$(sanitize_log_value "$workflow_name")\""
                    matched_existing_id="$final_id"
                    [[ -z "$match_strategy" ]] && match_strategy="manifest-id"
                    manifest_action="update"
                fi
            # Check current import batch for duplicate IDs
            elif [[ -n "${staged_workflows_by_id[$final_id]:-}" ]]; then
                local staged_name="${staged_workflows_by_id[$final_id]}"
                sanitization_note="id_conflict_in_batch"
                log DEBUG "Manifest ID $final_id for \"$(sanitize_log_value "$workflow_name")\" duplicates staged workflow \"$(sanitize_log_value "$staged_name")\" — clearing to avoid collision"
                final_id=""
            fi
        fi

        if [[ -n "$final_id" && -z "$matched_existing_id" ]]; then
            if [[ -n "${existing_workflows_by_id[$final_id]:-}" ]]; then
                matched_existing_id="$final_id"
                [[ -z "$match_strategy" ]] && match_strategy="manifest-id"
                manifest_action="update"
            fi
        fi

        if [[ -z "$final_id" ]]; then
            ids_reset=$((ids_reset + 1))
        else
            if [[ -n "$matched_existing_id" ]]; then
                ids_reused=$((ids_reused + 1))
            fi
        fi
        
        # Create sanitized workflow JSON with tag normalization
        # Set or remove .id based on finalId, normalize tags and active consistently
        local sanitized_json
        sanitized_json=$(printf '%s' "$workflow_json" | jq --arg finalId "$final_id" '
            # Normalize tags to proper format (single definition)
            def normalize_tag:
              if type == "object" then
                (.name // .label // .value // (if has("id") and ((.id|tostring)|length > 0) then ("tag-" + (.id|tostring)) else empty end))
              else
                .
              end;

            def ensure_array:
              if type == "array" then .
              elif . == null then []
              else [.] end;

            # Apply id policy: either assign finalId or remove id
            if $finalId == "" then del(.id) else .id = $finalId end
            | .active = (if (.active | type) == "boolean" then .active else false end)
            | .tags = (
                (.tags // []
                  | ensure_array
                  | map(
                      normalize_tag
                      | select(. != null)
                      | tostring
                      | gsub("^\\s+|\\s+$"; "")
                      | select(length > 0)
                      | {name: .}
                    )
                  | unique_by(.name)
                )
              )
        ' 2>/dev/null) || {
            log WARN "Failed to sanitize workflow JSON for $workflow_file"
            sanitized_json="$workflow_json"
        }
        
        # Write to staging directory (preserve directory structure)
        local staged_file="$staging_dir/$relative_path"
        mkdir -p "$(dirname "$staged_file")"
        printf '%s' "$sanitized_json" > "$staged_file"
        chmod 600 "$staged_file"
        
        # Record in manifest (NDJSON format - one JSON object per line)
        local manifest_entry
        manifest_entry=$(jq -nc \
            --arg originalId "$original_id" \
            --arg finalId "$final_id" \
            --arg name "$workflow_name" \
            --arg path "$relative_path" \
            --arg folder "$folder_path" \
            --arg note "$sanitization_note" \
            --arg existingId "$matched_existing_id" \
            --arg matchStrategy "$match_strategy" \
            --arg intent "$manifest_action" \
            '{
                id: (if $finalId == "" then null else $finalId end),
                originalWorkflowId: $originalId,
                assignedWorkflowId: (if $finalId == "" then null else $finalId end),
                existingWorkflowId: (if $existingId == "" then null else $existingId end),
                name: $name,
                storagePath: $path,
                targetFolder: $folder,
                sanitizedIdNote: (if $note == "" then null else $note end),
                intendedImportAction: (if $intent == "" then null else $intent end),
                matchStrategy: (if $matchStrategy == "" then null else $matchStrategy end)
            }')
        
        printf '%s\n' "$manifest_entry" >> "$output_manifest_path"
        processed=$((processed + 1))
        
        # Track this workflow ID in the current batch to detect duplicates
        if [[ -n "$final_id" ]]; then
            staged_workflows_by_id["$final_id"]="$workflow_name"
        fi
        
    done < <(find "$source_dir" -type f -name "*.json" \
        ! -path "*/.credentials/*" \
        ! -name "credentials.json" \
        -print0 2>/dev/null)
    
    if [[ "$processed" -gt 0 ]]; then
        # Report counts: use ids_reused to indicate how many workflows will reuse existing IDs
        log INFO "$processed workflow(s) processed: $ids_reused will reuse existing IDs, $ids_reset will receive new IDs"
    fi
    
    if [[ "$processed" -eq 0 ]]; then
        log WARN "No workflows found in $source_dir"
        rm -rf "$staging_dir"
        return 1
    fi
    
    # Create target directory in container
    local create_cmd="rm -rf $container_target_dir && mkdir -p $container_target_dir"
    if ! dockExec "$container_id" "$create_cmd" false; then
        log ERROR "Failed to create container directory: $container_target_dir"
        rm -rf "$staging_dir"
        return 1
    fi
    
    # Copy staged files to container
    log DEBUG "Copying staged workflows to container"
    if ! docker cp "$staging_dir/." "${container_id}:${container_target_dir}/" 2>/dev/null; then
        log ERROR "Failed to copy workflows to container"
        rm -rf "$staging_dir"
        return 1
    fi
    
    # Cleanup
    rm -rf "$staging_dir"
    
    log SUCCESS "Successfully staged $processed workflow(s) in container directory: $container_target_dir"
    return 0
}
