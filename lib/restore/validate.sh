#!/usr/bin/env bash
# Validation post import

reconcile_imported_workflow_ids() {
    local pre_import_snapshot="$1"
    local post_import_snapshot="$2"
    local manifest_path="$3"
    local output_path="$4"

    if [[ -z "$post_import_snapshot" || ! -f "$post_import_snapshot" ]]; then
        log ERROR "Post-import workflow snapshot not available; cannot reconcile IDs"
        return 1
    fi

    if [[ -z "$manifest_path" || ! -f "$manifest_path" ]]; then
        log ERROR "Workflow staging manifest missing; cannot reconcile IDs"
        return 1
    fi
    
    # Validate manifest is not empty
    if [[ ! -s "$manifest_path" ]]; then
        log ERROR "Staging manifest is empty; cannot reconcile IDs"
        return 1
    fi

    # Create indexes of workflows for fast lookup
    local pre_workflows_by_id=$(mktemp -t n8n-pre-ids-XXXXXX.json)
    local post_workflows_by_id=$(mktemp -t n8n-post-ids-XXXXXX.json)
    local post_workflows_by_meta=$(mktemp -t n8n-post-meta-XXXXXX.json)
    local new_workflows_by_name=$(mktemp -t n8n-new-names-XXXXXX.json)
    
    # Build pre-import ID index
    if [[ -n "$pre_import_snapshot" && -f "$pre_import_snapshot" ]]; then
        jq -r '.[] | select(.id != null) | {key: .id, value: .} | @json' "$pre_import_snapshot" 2>/dev/null | \
            jq -s 'from_entries' > "$pre_workflows_by_id"
    else
        printf '{}' > "$pre_workflows_by_id"
    fi
    
    # Build post-import ID index
    jq -r '.[] | select(.id != null) | {key: .id, value: .} | @json' "$post_import_snapshot" 2>/dev/null | \
        jq -s 'from_entries' > "$post_workflows_by_id"
    
    # Build post-import meta index
    jq -r '.[] | select(.meta.instanceId != null) | 
        {key: (.meta.instanceId | ascii_downcase), value: .} | @json' "$post_import_snapshot" 2>/dev/null | \
        jq -s 'group_by(.key) | map({key: .[0].key, value: map(.value)}) | from_entries' > "$post_workflows_by_meta"
    
    # Build new workflows by name index (workflows in post but not in pre)
    jq -n --slurpfile pre "$pre_workflows_by_id" --slurpfile post "$post_import_snapshot" '
        $pre[0] as $preById |
        $post[0] as $postWorkflows |
        ($postWorkflows | map(select($preById[.id] == null)) | 
         group_by(.name | ascii_downcase) | 
         map({key: .[0].name | ascii_downcase, value: .}) | from_entries)
    ' > "$new_workflows_by_name"
    
    # Process manifest line by line and update in place
    local reconciled_tmp=$(mktemp -t n8n-reconciled-XXXXXX.ndjson)
    local created=0 updated=0 unresolved=0
    local line_count=0
    
    while IFS= read -r entry_line; do
        # Skip empty lines
        [[ -z "$entry_line" ]] && continue
        
        # Skip lines that aren't valid JSON
        if ! printf '%s' "$entry_line" | jq empty 2>/dev/null; then
            if [[ "$verbose" == "true" ]]; then
                log DEBUG "Skipping invalid JSON line in manifest"
            fi
            continue
        fi
        
        line_count=$((line_count + 1))
        
        # Extract key fields from manifest entry
        local manifest_id=$(printf '%s' "$entry_line" | jq -r '.id // ""')
        local existing_id=$(printf '%s' "$entry_line" | jq -r '.existingWorkflowId // ""')
        local original_id=$(printf '%s' "$entry_line" | jq -r '.originalWorkflowId // ""')
        local meta_id=$(printf '%s' "$entry_line" | jq -r '.metaInstanceId // "" | ascii_downcase')
        local entry_name=$(printf '%s' "$entry_line" | jq -r '.name // "" | ascii_downcase')
        local sanitize_note=$(printf '%s' "$entry_line" | jq -r '.sanitizedIdNote // ""')
        
        local resolved_id="" resolution_strategy="" resolution_note=""
        
        # Strategy 1: manifest-id - Check if the ID from the file exists in post-import
        if [[ -z "$resolved_id" && -n "$manifest_id" ]]; then
            if jq -e --arg id "$manifest_id" '.[$id] != null' "$post_workflows_by_id" &>/dev/null; then
                resolved_id="$manifest_id"
                resolution_strategy="manifest-id"
            fi
        fi
        
        # Strategy 2: existing-workflow-id - Check if existingWorkflowId is in post-import
        if [[ -z "$resolved_id" && -n "$existing_id" && -z "$sanitize_note" ]]; then
            if jq -e --arg id "$existing_id" '.[$id] != null' "$post_workflows_by_id" &>/dev/null; then
                resolved_id="$existing_id"
                resolution_strategy="existing-workflow-id"
            fi
        fi
        
        # Strategy 3: original-workflow-id - Check if originalWorkflowId is in post-import
        if [[ -z "$resolved_id" && -n "$original_id" && -z "$sanitize_note" ]]; then
            if jq -e --arg id "$original_id" '.[$id] != null' "$post_workflows_by_id" &>/dev/null; then
                resolved_id="$original_id"
                resolution_strategy="original-workflow-id"
            fi
        fi
        
        # Strategy 4: meta-instance - Check if there's exactly one workflow with this instanceId
        if [[ -z "$resolved_id" && -n "$meta_id" ]]; then
            local meta_matches=$(jq --arg meta "$meta_id" '.[$meta] // [] | length' "$post_workflows_by_meta")
            if [[ "$meta_matches" == "1" ]]; then
                resolved_id=$(jq -r --arg meta "$meta_id" '.[$meta][0].id // ""' "$post_workflows_by_meta")
                resolution_strategy="meta-instance"
            elif [[ "$meta_matches" -gt 1 ]]; then
                resolution_note="Multiple workflows share instanceId"
            fi
        fi
        
        # Strategy 5: name-only - Check if there's exactly one new workflow with this name
        if [[ -z "$resolved_id" && -n "$entry_name" ]]; then
            local name_matches=$(jq --arg name "$entry_name" '.[$name] // [] | length' "$new_workflows_by_name")
            if [[ "$name_matches" == "1" ]]; then
                resolved_id=$(jq -r --arg name "$entry_name" '.[$name][0].id // ""' "$new_workflows_by_name")
                resolution_strategy="name-only"
            elif [[ "$name_matches" -gt 1 ]]; then
                if [[ -n "$resolution_note" ]]; then
                    resolution_note="$resolution_note; Multiple workflows share this name"
                else
                    resolution_note="Multiple workflows share this name"
                fi
            fi
        fi
        
        # Update entry with reconciliation results
        if [[ -n "$resolved_id" ]]; then
            # Successfully resolved - add reconciliation metadata
            local updated_entry=$(printf '%s' "$entry_line" | jq -c \
                --arg id "$resolved_id" \
                --arg strategy "$resolution_strategy" \
                --arg note "${sanitize_note:+$sanitize_note}" \
                '.id = $id | 
                 .actualImportedId = $id | 
                 .idReconciled = true | 
                 .idResolutionStrategy = $strategy |
                 (if ($note != "") then .idResolutionNote = $note else . end) |
                 del(.idReconciliationWarning)')
            
            printf '%s\n' "$updated_entry" >> "$reconciled_tmp"
            
            # Count as created or updated
            if [[ -n "$existing_id" ]]; then
                updated=$((updated + 1))
            else
                created=$((created + 1))
            fi
        else
            # Could not resolve - mark as unresolved
            local updated_entry=$(printf '%s' "$entry_line" | jq -c \
                --arg note "$resolution_note" \
                '.idReconciled = false | 
                 .idResolutionStrategy = "unresolved" | 
                 .actualImportedId = null |
                 (if ($note != "") then .idReconciliationWarning = $note else . end)')
            
            printf '%s\n' "$updated_entry" >> "$reconciled_tmp"
            unresolved=$((unresolved + 1))
        fi
    done < "$manifest_path"
    
    # Move reconciled manifest to output
    if [[ -s "$reconciled_tmp" ]]; then
        mv "$reconciled_tmp" "$output_path"
    else
        log ERROR "Reconciliation produced empty manifest (processed $line_count lines)"
        rm -f "$reconciled_tmp" "$pre_workflows_by_id" "$post_workflows_by_id" "$post_workflows_by_meta" "$new_workflows_by_name"
        return 1
    fi
    
    # Cleanup temp files
    rm -f "$pre_workflows_by_id" "$post_workflows_by_id" "$post_workflows_by_meta" "$new_workflows_by_name"
    
    # Validate counts
    local processed_total=$((created + updated + unresolved))
    if [[ "$processed_total" -ne "$line_count" ]]; then
        log WARN "Reconciliation count mismatch: processed $line_count lines, but only categorized $processed_total workflows"
    fi
    
    # Export metrics for summary
    local total_workflows=$((created + updated))
    local post_count
    if ! post_count=$(jq -r "$WORKFLOW_COUNT_FILTER" "$post_import_snapshot" 2>/dev/null); then
        post_count=0
    elif [[ -z "$post_count" || "$post_count" == "null" ]]; then
        post_count=0
    fi
    
    export RESTORE_WORKFLOWS_CREATED="$created"
    export RESTORE_WORKFLOWS_UPDATED="$updated"
    export RESTORE_POST_IMPORT_COUNT="$post_count"
    
    if [[ "$verbose" == "true" ]]; then
        log DEBUG "Reconciliation complete: processed=$line_count, created=$created, updated=$updated, unresolved=$unresolved, total=$total_workflows, post_count=$post_count"
    fi
    
    if [[ "$unresolved" -gt 0 ]]; then
        log WARN "Failed to reconcile IDs for $unresolved workflow(s); folder assignments may be incomplete"
    fi

    return 0
}
