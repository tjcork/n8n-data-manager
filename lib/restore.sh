#!/usr/bin/env bash
# =========================================================
# lib/restore.sh - Restore operations for n8n-manager
# =========================================================
# All restore-related functions: restore process, rollback

# Source required modules
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

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

sanitize_slug() {
    local value="$1"
    value="${value//$'\r'/}"
    value="${value//$'\n'/}"
    value="${value//$'\t'/}"
    value="${value// /_}"
    value="${value//\//_}"
    value="$(printf '%s' "$value" | sed 's/[^A-Za-z0-9._-]//g')"
    printf '%s\n' "$value"
}

unslug_to_title() {
    local slug="$1"
    if [[ -z "$slug" || "$slug" == "null" ]]; then
        printf '%s\n' "Folder"
        return
    fi

    local value="$slug"
    value="${value//_/ }"
    value="${value//-/ }"
    value="${value//./ }"

    # Collapse multiple spaces and trim edges
    value="$(printf '%s' "$value" | tr -s ' ')"
    value="$(printf '%s' "$value" | sed 's/^ *//;s/ *$//')"
    if [[ -z "$value" ]]; then
        value="Folder"
    fi

    printf '%s\n' "$value"
}

validate_credentials_payload() {
    local credentials_path="$1"

    if [[ ! -f "$credentials_path" ]]; then
        log ERROR "Credentials file not found for validation: $credentials_path"
        return 1
    fi

    local jq_temp_err
    jq_temp_err=$(mktemp -t n8n-cred-validate-err-XXXXXXXX.log)
    if ! jq empty "$credentials_path" 2>"$jq_temp_err"; then
        local jq_error
        jq_error=$(cat "$jq_temp_err" 2>/dev/null)
        rm -f "$jq_temp_err"
        log ERROR "Unable to parse credentials file for validation: $credentials_path"
        if [[ -n "$jq_error" ]]; then
            log DEBUG "jq parse error: $jq_error"
        fi
        return 1
    fi
    rm -f "$jq_temp_err"

    local invalid_entries
    invalid_entries=$(jq -r '
        [ .[]
            | select((has("data") | not) or ((.data | type) != "object"))
            | (.name // (if has("id") then ("ID:" + (.id|tostring)) else "unknown" end))
        ]
        | unique
        | join(", ")
    ' "$credentials_path") || invalid_entries=""

    if [[ -n "$invalid_entries" ]]; then
        log ERROR "Credentials still contain encrypted or invalid data for: $invalid_entries"
        return 1
    fi

    local basic_filter_file
    basic_filter_file=$(mktemp -t n8n-cred-basic-filter-XXXXXXXX.jq)
    cat <<'JQ_FILTER' > "$basic_filter_file"
def safe_credential_value($credential; $field):
    (if ($credential.data // empty) | type == "object" then $credential.data[$field] else empty end) // "";

[ .[]
    | select((.type // "") == "httpBasicAuth")
    | select(
        ((.data // empty) | type) != "object"
        or (safe_credential_value(.; "user") | tostring | length) == 0
        or (safe_credential_value(.; "password") | tostring | length) == 0
    )
    | (.name // (if has("id") then ("ID:" + (.id|tostring)) else "unknown" end))
] | unique | join(", ")
JQ_FILTER

    local basic_missing
    basic_missing=$(jq -r -f "$basic_filter_file" "$credentials_path") || basic_missing=""
    rm -f "$basic_filter_file"

    if [[ -n "$basic_missing" ]]; then
        rm -f "$normalized_json"
        log ERROR "Basic Auth credentials missing username or password: $basic_missing"
        return 1
    fi

    rm -f "$jq_temp_err"
    return 0
}

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

summarize_manifest_assignment_status() {
    local manifest_path="$1"
    local summary_label="$2"

    if [[ -z "$manifest_path" || ! -f "$manifest_path" ]]; then
        return 0
    fi

    # Determine manifest format (NDJSON vs JSON array/object)
    local entry_format="ndjson"
    if jq -e '.' "$manifest_path" >/dev/null 2>&1; then
        if jq -e 'type == "array"' "$manifest_path" >/dev/null 2>&1; then
            entry_format="array"
        elif jq -e 'type == "object" and has("workflows") and (.workflows | type == "array")' "$manifest_path" >/dev/null 2>&1; then
            entry_format="workflows-object"
        fi
    fi

    # Process manifest entries and compute summary stats
    local total=0 resolved=0 unresolved=0
    declare -A strategy_counts=()
    local -a warnings=()
    while IFS= read -r entry_line; do
        [[ -z "$entry_line" ]] && continue

        if ! printf '%s' "$entry_line" | jq empty >/dev/null 2>&1; then
            if [[ "$verbose" == "true" ]]; then
                log DEBUG "Skipping invalid manifest entry while summarizing"
            fi
            continue
        fi

        total=$((total + 1))

        local is_reconciled=$(printf '%s' "$entry_line" | jq -r '.idReconciled // false' 2>/dev/null)
        local strategy=$(printf '%s' "$entry_line" | jq -r '.idResolutionStrategy // ""' 2>/dev/null)
        local warning_text=$(printf '%s' "$entry_line" | jq -r '.idReconciliationWarning // ""' 2>/dev/null)
        local entry_name=$(printf '%s' "$entry_line" | jq -r '.name // "Workflow"' 2>/dev/null)

        if [[ "$is_reconciled" == "true" ]]; then
            resolved=$((resolved + 1))
        else
            unresolved=$((unresolved + 1))
        fi
        
        if [[ -n "$strategy" ]]; then
            strategy_counts["$strategy"]=$((${strategy_counts["$strategy"]:-0} + 1))
        fi
        
        if [[ "$is_reconciled" != "true" && -n "$warning_text" ]]; then
            warnings+=("${entry_name}\t${warning_text}")
        fi
    done < <(
        {
            case "$entry_format" in
                array)
                    jq -c '.[]' "$manifest_path" 2>/dev/null || true
                    ;;
                workflows-object)
                    jq -c '.workflows[]' "$manifest_path" 2>/dev/null || true
                    ;;
                *)
                    cat "$manifest_path" 2>/dev/null || true
                    ;;
            esac
        }
    )

    if [[ "$total" -eq 0 ]]; then
        return 0
    fi

    local label_suffix=""
    if [[ -n "$summary_label" ]]; then
        label_suffix=" ($summary_label)"
    fi

    log INFO "Workflow manifest reconciliation summary${label_suffix}: ${resolved}/${total} resolved, ${unresolved} unresolved."

    if [[ "$verbose" == "true" ]]; then
        for strategy in "${!strategy_counts[@]}"; do
            local count="${strategy_counts[$strategy]}"
                log DEBUG "  • Strategy '${strategy}': ${count} workflow(s)"
        done

        local warning_index=0
        for warning in "${warnings[@]}"; do
            IFS=$'\t' read -r warn_name warn_text <<< "$warning"
            if [[ -n "$warn_text" ]]; then
                log DEBUG "  ⚠️  ${warn_name}: ${warn_text}"
            fi
            warning_index=$((warning_index + 1))
            if (( warning_index >= 5 )); then
                break
            fi
        done
    fi
    return 0
}

apply_folder_structure_from_directory() {
    local source_dir="$1"
    local container_id="$2"
    local is_dry_run="$3"
    local container_credentials_path="$4"
    local staged_manifest_path="${5:-}"

    if [[ "$is_dry_run" == "true" ]]; then
        log DRYRUN "Would restore folder structure by scanning directory: $source_dir"
        return 0
    fi

    if [[ -z "$source_dir" || ! -d "$source_dir" ]]; then
    log WARN "Workflow directory not found: ${source_dir:-<empty>}"
        return 0
    fi

    local entries_tmp
    entries_tmp=$(mktemp -t n8n-structure-entries-XXXXXXXX.json)
    if ! collect_directory_structure_entries "$source_dir" "$entries_tmp" "$staged_manifest_path"; then
        rm -f "$entries_tmp"
        log WARN "Unable to derive folder layout from directory; skipping folder restoration."
        return 0
    fi

    summarize_manifest_assignment_status "$entries_tmp" "folder structure"

    local result=0
    if ! apply_directory_structure_entries "$entries_tmp" "$container_id" "$is_dry_run" "$container_credentials_path"; then
        result=1
    fi

    rm -f "$entries_tmp"
    return $result
}

normalize_manifest_lookup_key() {
    local raw_input="${1:-}"
    if [[ -z "$raw_input" ]]; then
        printf ''
        return 0
    fi

    local normalized="$raw_input"
    normalized="${normalized//$'\r'/}"
    normalized="${normalized//$'\n'/}"
    normalized="${normalized//$'\t'/}"
    normalized="${normalized//\\/\/}"
    normalized=$(printf '%s' "$normalized" | tr -s ' ')
    normalized=$(printf '%s' "$normalized" | sed 's/^[[:space:]]\+//; s/[[:space:]]\+$//')
    normalized=$(printf '%s' "$normalized" | sed 's:[[:space:]]*/[[:space:]]*:/:g')
    normalized=$(printf '%s' "$normalized" | sed 's:/\{2,\}:/:g')
    normalized=$(printf '%s' "$normalized" | tr '[:upper:]' '[:lower:]')
    normalized="${normalized#/}"
    normalized="${normalized%/}"

    if [[ -z "$normalized" ]]; then
        printf ''
        return 0
    fi

    printf '%s' "$normalized"
    return 0
}

manifest_lookup_path_matches() {
    local candidate="${1:-}"
    local expected="${2:-}"
    local project_prefix="${3:-}"

    if [[ -z "$candidate" || -z "$expected" ]]; then
        return 1
    fi

    if [[ "$candidate" == "$expected" ]]; then
        return 0
    fi

    local -a prefixes=()
    if [[ -n "$project_prefix" ]]; then
        prefixes+=("$project_prefix")
    fi
    if [[ -z "$project_prefix" || "$project_prefix" != "personal" ]]; then
        prefixes+=("personal")
    fi

    local prefix
    for prefix in "${prefixes[@]}"; do
        [[ -z "$prefix" ]] && continue

        local candidate_prefix="${candidate%%/*}"
        if [[ "$candidate_prefix" == "$prefix" && "$candidate" != "$prefix" ]]; then
            local candidate_without_prefix="${candidate#*/}"
            if [[ "$candidate_without_prefix" == "$expected" ]]; then
                return 0
            fi
        fi

        local expected_prefix="${expected%%/*}"
        if [[ "$expected_prefix" == "$prefix" && "$expected" != "$prefix" ]]; then
            local expected_without_prefix="${expected#*/}"
            if [[ "$expected_without_prefix" == "$candidate" ]]; then
                return 0
            fi
        fi
    done

    return 1
}

normalize_manifest_id_key() {
    local raw_input="${1:-}"
    if [[ -z "$raw_input" ]]; then
        printf ''
        return 0
    fi

    local normalized="$raw_input"
    normalized="${normalized//$'\r'/}"
    normalized="${normalized//$'\n'/}"
    normalized="${normalized//$'\t'/}"
    normalized=$(printf '%s' "$normalized" | tr -d ' ')
    normalized=$(printf '%s' "$normalized" | tr '[:upper:]' '[:lower:]')

    if [[ -z "$normalized" ]]; then
        printf ''
        return 0
    fi

    printf '%s' "$normalized"
    return 0
}

build_manifest_name_key() {
    local folder_path="${1:-}"
    local workflow_name="${2:-}"

    local name_norm
    name_norm=$(normalize_manifest_lookup_key "$workflow_name")
    if [[ -z "$name_norm" ]]; then
        printf ''
        return 0
    fi

    local folder_norm
    folder_norm=$(normalize_manifest_lookup_key "$folder_path")
    if [[ -n "$folder_norm" ]]; then
        printf '%s|%s' "$folder_norm" "$name_norm"
    else
        printf '%s' "$name_norm"
    fi
    return 0
}

assign_manifest_lookup_entry() {
    local entries_name="$1"
    local scores_name="$2"
    local updates_name="$3"
    local key="$4"
    local score="$5"
    local updated="$6"
    local payload="$7"

    if [[ -z "$key" ]]; then
        return 0
    fi

    declare -n entries_ref="$entries_name"
    declare -n scores_ref="$scores_name"
    declare -n updates_ref="$updates_name"

    local existing_payload="${entries_ref[$key]:-}"
    if [[ -z "$existing_payload" ]]; then
        entries_ref["$key"]="$payload"
        scores_ref["$key"]="${score:-0}"
        updates_ref["$key"]="$updated"
        return 0
    fi

    local existing_score="${scores_ref[$key]:-0}"
    if (( ${score:-0} > existing_score )); then
        entries_ref["$key"]="$payload"
        scores_ref["$key"]="${score:-0}"
        updates_ref["$key"]="$updated"
        return 0
    fi
    if (( ${score:-0} < existing_score )); then
        return 0
    fi

    local existing_updated="${updates_ref[$key]:-}"
    if [[ -z "$existing_updated" ]]; then
        if [[ -n "$updated" ]]; then
            entries_ref["$key"]="$payload"
            updates_ref["$key"]="$updated"
        fi
        return 0
    fi

    if [[ -n "$updated" && "$updated" > "$existing_updated" ]]; then
        entries_ref["$key"]="$payload"
        updates_ref["$key"]="$updated"
    fi

    return 0
}

compute_entry_folder_context() {
    local relative_dir="${1:-}"
    local project_slug_ref="$2"
    local project_display_ref="$3"
    local folder_slugs_ref="$4"
    local folder_displays_ref="$5"
    local display_path_ref="$6"

    declare -n _project_slug_ref="$project_slug_ref"
    declare -n _project_display_ref="$project_display_ref"
    declare -n _folder_slugs_ref="$folder_slugs_ref"
    declare -n _folder_displays_ref="$folder_displays_ref"
    declare -n _display_path_ref="$display_path_ref"

    _project_slug_ref=""
    _project_display_ref=""
    _folder_slugs_ref=()
    _folder_displays_ref=()
    _display_path_ref=""

    local normalized="$relative_dir"
    normalized="${normalized//\\/\/}"
    normalized=$(printf '%s' "$normalized" | sed 's/[[:space:]]\+/ /g; s/^ *//; s/ *$//')
    normalized=$(printf '%s' "$normalized" | sed 's:/\+:/:g')
    normalized="${normalized#/}"
    normalized="${normalized%/}"

    local -a segments=()
    if [[ -n "$normalized" ]]; then
        IFS='/' read -r -a segments <<< "$normalized"
        local idx
        for idx in "${!segments[@]}"; do
            local trimmed
            trimmed=$(printf '%s' "${segments[$idx]}" | sed 's/^[[:space:]]\+//;s/[[:space:]]\+$//')
            if [[ -z "$trimmed" ]]; then
                unset 'segments[$idx]'
            else
                segments[$idx]="$trimmed"
            fi
        done
        segments=("${segments[@]}")
    fi

    local configured_project_name="${project_name:-}"
    local configured_project_slug="${project_slug:-}"
    if [[ -z "$configured_project_name" || "$configured_project_name" == "null" ]]; then
        configured_project_name=""
    fi
    if [[ -z "$configured_project_slug" || "$configured_project_slug" == "null" ]]; then
        configured_project_slug=""
    fi
    if [[ -n "$configured_project_slug" ]]; then
        configured_project_slug="$(sanitize_slug "$configured_project_slug")"
    fi
    if [[ -z "$configured_project_slug" && -n "$configured_project_name" ]]; then
        configured_project_slug="$(sanitize_slug "$configured_project_name")"
    fi
    if [[ -z "$configured_project_slug" ]]; then
        configured_project_slug="personal"
    fi

    local configured_project_display="$configured_project_name"
    if [[ -z "$configured_project_display" ]]; then
        configured_project_display="$(unslug_to_title "$configured_project_slug")"
    fi

    local -a folder_segments=("${segments[@]}")

    if ((${#folder_segments[@]} > 0)); then
        local first_segment_slug
        first_segment_slug=$(sanitize_slug "${folder_segments[0]}")
        if [[ -n "$first_segment_slug" ]]; then
            local first_lower
            first_lower=$(printf '%s' "$first_segment_slug" | tr '[:upper:]' '[:lower:]')
            local project_lower
            project_lower=$(printf '%s' "$configured_project_slug" | tr '[:upper:]' '[:lower:]')
            if [[ "$first_lower" == "$project_lower" ]]; then
                folder_segments=("${folder_segments[@]:1}")
            fi
        fi
    fi

    _folder_slugs_ref=()
    _folder_displays_ref=()

    local -a base_folder_slugs=()
    local -a base_folder_displays=()

    if [[ -n "$n8n_path" ]]; then
        local path_prefix_trimmed
        path_prefix_trimmed="${n8n_path#/}"
        path_prefix_trimmed="${path_prefix_trimmed%/}"
        if [[ -n "$path_prefix_trimmed" ]]; then
            local -a _path_segments=()
            IFS='/' read -r -a _path_segments <<< "$path_prefix_trimmed"
            local base_segment
            for base_segment in "${_path_segments[@]}"; do
                [[ -z "$base_segment" ]] && continue
                local base_slug
                base_slug=$(sanitize_slug "$base_segment")
                [[ -z "$base_slug" ]] && continue
                local base_display_part
                base_display_part="$(unslug_to_title "$base_slug")"
                base_folder_slugs+=("$base_slug")
                base_folder_displays+=("$base_display_part")
            done
        fi
    fi

    local project_lower
    project_lower=$(printf '%s' "$configured_project_slug" | tr '[:upper:]' '[:lower:]')

    local idx
    for idx in "${!base_folder_slugs[@]}"; do
        local base_slug="${base_folder_slugs[$idx]}"
        local base_lower
        base_lower=$(printf '%s' "$base_slug" | tr '[:upper:]' '[:lower:]')
        if [[ "$base_lower" == "$project_lower" ]]; then
            continue
        fi
        local base_display="${base_folder_displays[$idx]}"
        if [[ -z "$base_display" ]]; then
            base_display="$(unslug_to_title "$base_slug")"
        fi
        _folder_slugs_ref+=("$base_slug")
        _folder_displays_ref+=("$base_display")
    done

    local initial_base_count=${#_folder_slugs_ref[@]}

    local segment
    local seg_index=0
    for segment in "${folder_segments[@]}"; do
        local slug
        slug=$(sanitize_slug "$segment")
        if [[ -z "$slug" ]]; then
            slug=$(sanitize_slug "$(unslug_to_title "$segment")")
        fi
        if [[ -z "$slug" ]]; then
            continue
        fi
        local slug_lower
        slug_lower=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')
        if (( seg_index < initial_base_count )); then
            local existing_lower
            existing_lower=$(printf '%s' "${_folder_slugs_ref[$seg_index]}" | tr '[:upper:]' '[:lower:]')
            if [[ "$existing_lower" == "$slug_lower" ]]; then
                seg_index=$((seg_index + 1))
                continue
            fi
        fi
        _folder_slugs_ref+=("$slug")
        if [[ -n "$segment" ]]; then
            _folder_displays_ref+=("$segment")
        else
            _folder_displays_ref+=("$(unslug_to_title "$slug")")
        fi
        seg_index=$((seg_index + 1))
    done

    _project_slug_ref="$configured_project_slug"
    _project_display_ref="$configured_project_display"

    if ((${#_folder_displays_ref[@]} > 0)); then
        local assembled="${_folder_displays_ref[0]}"
        local i
        for ((i=1; i<${#_folder_displays_ref[@]}; i++)); do
            assembled+=" / ${_folder_displays_ref[$i]}"
        done
        _display_path_ref="$assembled"
    else
        _display_path_ref=""
    fi

    return 0
}

collect_directory_structure_entries() {
    local source_dir="$1"
    local output_path="$2"
    local manifest_path="${3:-}"

    if [[ -z "$source_dir" || ! -d "$source_dir" ]]; then
        log ERROR "Cannot derive folder structure from directory - missing path: ${source_dir:-<empty>}"
        return 1
    fi

    if [[ -z "$output_path" ]]; then
        log ERROR "Output path not provided for directory-derived folder structure entries"
        return 1
    fi

    local entries_file
    entries_file=$(mktemp -t n8n-directory-entries-XXXXXXXX.json)
    printf '[]' > "$entries_file"

    local success=true
    local processed=0

    local manifest_indexed=false
    declare -A manifest_path_entries=()
    declare -A manifest_path_scores=()
    declare -A manifest_path_updates=()
    declare -A manifest_id_entries=()
    declare -A manifest_id_scores=()
    declare -A manifest_id_updates=()
    declare -A manifest_folder_name_entries=()
    declare -A manifest_folder_name_scores=()
    declare -A manifest_folder_name_updates=()

    if [[ -n "$manifest_path" && -f "$manifest_path" ]]; then
        if [[ "$verbose" == "true" ]]; then
            log DEBUG "Indexing staged manifest from $manifest_path"
        fi

        # Process NDJSON manifest line-by-line to build indexes
        local manifest_line entry_score entry_updated path_key name_key payload
        while IFS= read -r manifest_line; do
            [[ -z "$manifest_line" ]] && continue

            # Extract normalized keys using jq
            entry_score=$(printf '%s' "$manifest_line" | jq -r '
                if (.actualImportedId // "" | length) > 0 then 400
                elif (.id // "" | length) > 0 then 300
                elif (.existingWorkflowId // "" | length) > 0 then 200
                elif (.originalWorkflowId // "" | length) > 0 then 100
                else 0 end
            ' 2>/dev/null || printf '0')
            
            entry_updated=$(printf '%s' "$manifest_line" | jq -r '.updatedAt // .metaUpdatedAt // .importedAt // ""' 2>/dev/null)
            
            # Compute normalized path key: storagePath/filename
            path_key=$(printf '%s' "$manifest_line" | jq -r '
                def norm(v):
                    (v // "")
                    | gsub("\\\\\\\\"; "/")
                    | gsub("[[:space:]]+"; " ")
                    | ascii_downcase
                    | gsub("^ "; "")
                    | gsub(" $"; "")
                    | gsub("/+"; "/")
                    | gsub("^/"; "")
                    | gsub("/$"; "");
                
                if (.storagePath // "" | length) > 0 and (.filename // "" | length) > 0 then
                    norm((.storagePath // "") + "/" + (.filename // ""))
                elif (.filename // "" | length) > 0 then
                    norm(.filename)
                else "" end
            ' 2>/dev/null)
            
            # Compute normalized name key: storagePath|name
            name_key=$(printf '%s' "$manifest_line" | jq -r '
                def norm(v):
                    (v // "")
                    | gsub("\\\\\\\\"; "/")
                    | gsub("[[:space:]]+"; " ")
                    | ascii_downcase
                    | gsub("^ "; "")
                    | gsub(" $"; "")
                    | gsub("/+"; "/")
                    | gsub("^/"; "")
                    | gsub("/$"; "");
                
                if (.name // "" | length) == 0 then ""
                else
                    norm(.name) as $n |
                    if ($n | length) == 0 then ""
                    else
                        norm(.storagePath) as $s |
                        if ($s | length) > 0 then $s + "|" + $n else $n end
                    end
                end
            ' 2>/dev/null)
            
            payload="$manifest_line"

            assign_manifest_lookup_entry manifest_path_entries manifest_path_scores manifest_path_updates "$path_key" "$entry_score" "$entry_updated" "$payload"
            assign_manifest_lookup_entry manifest_folder_name_entries manifest_folder_name_scores manifest_folder_name_updates "$name_key" "$entry_score" "$entry_updated" "$payload"

            # Extract all ID fields and index by them
            local -a id_keys=()
            mapfile -t id_keys < <(printf '%s' "$manifest_line" | jq -r '
                [.actualImportedId, .id, .existingWorkflowId, .originalWorkflowId] 
                | map(select(. != null and (. | tostring | length) > 0) | tostring | gsub("[[:space:]]+"; "") | ascii_downcase) 
                | unique[]
            ' 2>/dev/null)
            
            for id_key in "${id_keys[@]}"; do
                [[ -z "$id_key" ]] && continue
                assign_manifest_lookup_entry manifest_id_entries manifest_id_scores manifest_id_updates "$id_key" "$entry_score" "$entry_updated" "$payload"
            done

            manifest_indexed=true
        done < "$manifest_path"

        if [[ "$verbose" == "true" ]]; then
            log DEBUG "Indexed staged manifest entries for folder lookup (path=${#manifest_path_entries[@]}, id=${#manifest_id_entries[@]}, folder-name=${#manifest_folder_name_entries[@]})"
        fi
    fi

    while IFS= read -r -d '' workflow_file; do
        local filename
        filename=$(basename "$workflow_file")

        local relative
        relative="${workflow_file#$source_dir/}"
        if [[ "$relative" == "$workflow_file" ]]; then
            relative="$filename"
        fi

        local relative_dir
        relative_dir="${relative%/*}"
        if [[ "$relative_dir" == "$relative" ]]; then
            relative_dir=""
        fi
        relative_dir="${relative_dir%/}"

        local canonical_relative_path
        canonical_relative_path="$(strip_github_path_prefix "$relative")"
        canonical_relative_path="${canonical_relative_path#/}"
        canonical_relative_path="${canonical_relative_path%/}"

        local raw_storage_path="$relative_dir"
        raw_storage_path="${raw_storage_path#/}"
        raw_storage_path="${raw_storage_path%/}"

        local relative_dir_without_prefix
        relative_dir_without_prefix="$(strip_github_path_prefix "$raw_storage_path")"
        relative_dir_without_prefix="${relative_dir_without_prefix#/}"
        relative_dir_without_prefix="${relative_dir_without_prefix%/}"

        local storage_path
        storage_path="$(compose_repo_storage_path "$relative_dir_without_prefix")"
        storage_path="${storage_path#/}"
        storage_path="${storage_path%/}"

        if [[ -n "$storage_path" ]] && ! path_matches_github_prefix "$storage_path"; then
            log DEBUG "Skipping workflow outside configured GITHUB_PATH: $workflow_file"
            continue
        fi

        local manifest_entry=""
        local manifest_existing_id=""
        local manifest_original_id=""
        local manifest_actual_id=""
        local manifest_strategy=""
        local manifest_warning=""
        local manifest_note=""
        local manifest_entry_source=""
    local manifest_target_slug_path=""
    local manifest_target_display_path=""
    local manifest_target_project_slug=""
    local manifest_target_project_name=""

        local workflow_id_from_file=""
        local workflow_name_from_file=""
        local workflow_metadata=""
        if workflow_metadata=$(jq -c '{id: (.id // empty), name: (.name // empty)}' "$workflow_file" 2>/dev/null); then
            workflow_id_from_file=$(printf '%s' "$workflow_metadata" | jq -r '.id // empty' 2>/dev/null)
            workflow_name_from_file=$(printf '%s' "$workflow_metadata" | jq -r '.name // empty' 2>/dev/null)
        fi

        if $manifest_indexed; then
            local manifest_path_candidate="$filename"
            if [[ -n "$storage_path" ]]; then
                manifest_path_candidate="${storage_path%/}/$filename"
            fi
            local path_norm
            path_norm=$(normalize_manifest_lookup_key "$manifest_path_candidate")
            local id_norm
            id_norm=$(normalize_manifest_id_key "$workflow_id_from_file")
            local name_norm
            name_norm=$(build_manifest_name_key "$storage_path" "$workflow_name_from_file")

            # Perform manifest lookups
            if [[ -n "$path_norm" && -n "${manifest_path_entries[$path_norm]+set}" ]]; then
                manifest_entry="${manifest_path_entries[$path_norm]}"
                manifest_entry_source="path"
            fi
            if [[ -z "$manifest_entry" && -n "$id_norm" && -n "${manifest_id_entries[$id_norm]+set}" ]]; then
                manifest_entry="${manifest_id_entries[$id_norm]}"
                manifest_entry_source="workflow-id"
            fi
            if [[ -z "$manifest_entry" && -n "$name_norm" && -n "${manifest_folder_name_entries[$name_norm]+set}" ]]; then
                manifest_entry="${manifest_folder_name_entries[$name_norm]}"
                manifest_entry_source="folder-name"
            fi
        fi

        if [[ -n "$manifest_entry" ]]; then
            manifest_existing_id=$(printf '%s' "$manifest_entry" | jq -r '.existingWorkflowId // empty' 2>/dev/null)
            manifest_original_id=$(printf '%s' "$manifest_entry" | jq -r '.originalWorkflowId // empty' 2>/dev/null)
            manifest_actual_id=$(printf '%s' "$manifest_entry" | jq -r '.actualImportedId // empty' 2>/dev/null)
            manifest_strategy=$(printf '%s' "$manifest_entry" | jq -r '.idResolutionStrategy // empty' 2>/dev/null)
            manifest_warning=$(printf '%s' "$manifest_entry" | jq -r '.idReconciliationWarning // empty' 2>/dev/null)
            manifest_note=$(printf '%s' "$manifest_entry" | jq -r '.idResolutionNote // empty' 2>/dev/null)
            manifest_target_slug_path=$(printf '%s' "$manifest_entry" | jq -r '.targetFolderSlugPath // empty' 2>/dev/null)
            manifest_target_display_path=$(printf '%s' "$manifest_entry" | jq -r '.targetFolderDisplayPath // empty' 2>/dev/null)
            manifest_target_project_slug=$(printf '%s' "$manifest_entry" | jq -r '.targetProjectSlug // empty' 2>/dev/null)
            manifest_target_project_name=$(printf '%s' "$manifest_entry" | jq -r '.targetProjectName // empty' 2>/dev/null)
            
            if [[ "$verbose" == "true" ]]; then
                log DEBUG "Matched manifest entry for '${workflow_name_from_file:-$filename}' via $manifest_entry_source (actualId=${manifest_actual_id:-none}, existingId=${manifest_existing_id:-none})"
            fi
        elif $manifest_indexed && [[ "$verbose" == "true" ]]; then
            log DEBUG "No manifest entry found for '$workflow_file'"
        fi

        # Sanitize manifest folder/project data
        if [[ -n "$manifest_target_slug_path" ]]; then
            manifest_target_slug_path="${manifest_target_slug_path#/}"
            manifest_target_slug_path="${manifest_target_slug_path%/}"
        fi
        if [[ -n "$manifest_target_display_path" ]]; then
            manifest_target_display_path="${manifest_target_display_path//$'\r'/}"
            manifest_target_display_path="${manifest_target_display_path//$'\n'/}"
        fi
        if [[ -n "$manifest_target_project_slug" ]]; then
            manifest_target_project_slug="$(sanitize_slug "$manifest_target_project_slug")"
        fi

        # Note: We don't override storage_path with manifest_target_slug_path here because:
        # 1. storage_path is used for internal path matching and should match the file system structure
        # 2. manifest_target_slug_path may contain old slug format (e.g., "Asana_3" instead of "Asana 3")
        # 3. Folder assignment will use manifest display/project data directly from manifest entries

        # PRIORITY ORDER for workflow ID resolution:
        # 1. Manifest (staged during import with injected IDs) - MOST RELIABLE
        # 2. Workflow file on disk (may not have ID if original backup didn't)
        # 3. Manifest existing ID (fallback for replacements)
        
        local workflow_id=""
        local workflow_id_source="none"

        # Try manifest FIRST (contains IDs after V4 injection)
        if [[ -n "$manifest_actual_id" ]]; then
            workflow_id="$manifest_actual_id"
            workflow_id_source="manifest-actual"
        elif [[ -n "$manifest_entry" ]]; then
            workflow_id=$(printf '%s' "$manifest_entry" | jq -r '.id // empty' 2>/dev/null)
            if [[ -n "$workflow_id" && "$workflow_id" != "null" ]]; then
                workflow_id_source="manifest-id"
            else
                workflow_id=""
            fi
        fi
        
        # Fallback to file if manifest doesn't have ID
        if [[ -z "$workflow_id" ]]; then
            if [[ -n "$workflow_id_from_file" && "$workflow_id_from_file" != "null" ]]; then
                workflow_id="$workflow_id_from_file"
                workflow_id_source="file"
            else
                workflow_id=""
            fi
        fi
        
        # Last resort: use existingWorkflowId from manifest
        if [[ -z "$workflow_id" && -n "$manifest_existing_id" ]]; then
            workflow_id="$manifest_existing_id"
            workflow_id_source="manifest_existing"
        fi

        local workflow_name
        workflow_name="$workflow_name_from_file"
        if [[ -z "$workflow_name" && -n "$manifest_entry" ]]; then
            workflow_name=$(printf '%s' "$manifest_entry" | jq -r '.name // empty' 2>/dev/null)
        fi
        if [[ -z "$workflow_name" || "$workflow_name" == "null" ]]; then
            workflow_name="Unnamed Workflow"
        fi

        if [[ "$verbose" == "true" && -n "$manifest_entry_source" && -n "$manifest_entry" ]]; then
            log DEBUG "Matched manifest entry for '$workflow_name' via ${manifest_entry_source} lookup."
        fi

        if [[ "$verbose" == "true" && -n "$manifest_entry" && -z "$manifest_actual_id" ]]; then
            local strategy_display="${manifest_strategy:-unresolved}"
            log DEBUG "Manifest entry for '$workflow_name' lacks reconciled ID (strategy: ${strategy_display})."
        fi

        if [[ -z "$workflow_id" && -n "$manifest_warning" ]]; then
            if [[ "$verbose" == "true" ]]; then
                log DEBUG "Manifest warning for '$workflow_name': $manifest_warning"
            fi
        fi

        if [[ -n "$manifest_note" && "$verbose" == "true" ]]; then
            log DEBUG "Manifest resolution note for '$workflow_name': $manifest_note"
        fi

        if [[ -z "$workflow_id" ]]; then
            log WARN "Collecting folder entry without workflow ID for '$workflow_name' (file: $filename, manifest available: $([[ -n "$manifest_entry" ]] && echo "yes" || echo "no"))"
        elif [[ "$verbose" == "true" ]]; then
            log DEBUG "Collected folder entry for '$workflow_name' with ID '$workflow_id' (source: $workflow_id_source)"
        fi

        local entry_project_slug=""
        local entry_project_display=""
        local -a folder_slugs=()
        local -a folder_displays=()
        local entry_display_path=""

        local folder_context_source="$relative_dir_without_prefix"
        if [[ -n "$manifest_target_slug_path" ]]; then
            folder_context_source="$manifest_target_slug_path"
        fi

        compute_entry_folder_context \
            "$folder_context_source" \
            entry_project_slug \
            entry_project_display \
            folder_slugs \
            folder_displays \
            entry_display_path

        if [[ -z "$entry_project_slug" ]]; then
            entry_project_slug="personal"
        fi
        if [[ -z "$entry_project_display" ]]; then
            entry_project_display=$(unslug_to_title "$entry_project_slug")
        fi

        if [[ -n "$manifest_target_project_slug" ]]; then
            entry_project_slug="$manifest_target_project_slug"
        fi
        if [[ -n "$manifest_target_project_name" ]]; then
            entry_project_display="$manifest_target_project_name"
        fi

        local relative_path="$canonical_relative_path"
        local display_path="$entry_display_path"
        if [[ -z "$display_path" ]]; then
            display_path="$entry_project_display"
        fi
        if [[ -z "$display_path" ]]; then
            display_path=$(unslug_to_title "$entry_project_slug")
        fi

        if [[ -n "$manifest_target_display_path" ]]; then
            display_path="$manifest_target_display_path"
        fi

        local manifest_project_slug=""
        local manifest_project_display=""
        local manifest_display_path=""
        if [[ -n "$manifest_entry" ]]; then
            manifest_project_slug=$(printf '%s' "$manifest_entry" | jq -r '.project.slug // empty' 2>/dev/null)
            manifest_project_display=$(printf '%s' "$manifest_entry" | jq -r '.project.name // empty' 2>/dev/null)
            manifest_display_path=$(printf '%s' "$manifest_entry" | jq -r '.displayPath // empty' 2>/dev/null)
        fi

        local folder_changed_note=""
        if [[ -n "$manifest_project_slug" && "$manifest_project_slug" != "$entry_project_slug" ]]; then
            local from_display="$manifest_project_display"
            if [[ -z "$from_display" ]]; then
                from_display=$(unslug_to_title "$manifest_project_slug")
            fi
            local to_display="$entry_project_display"
            if [[ -z "$to_display" ]]; then
                to_display=$(unslug_to_title "$entry_project_slug")
            fi
            folder_changed_note="Project adjusted to '$to_display' (was '$from_display')"
        fi

        if [[ -n "$manifest_display_path" && -n "$display_path" && "$manifest_display_path" != "$display_path" ]]; then
            folder_changed_note=$(append_sanitized_note "$folder_changed_note" "Folder path updated to '$display_path'")
        fi

        if [[ -n "$folder_changed_note" ]]; then
            manifest_note=$(append_sanitized_note "$manifest_note" "$folder_changed_note")
        fi

        local folder_array_file
        folder_array_file=$(mktemp -t n8n-folder-array-XXXXXXXX.json)
        printf '[]' > "$folder_array_file"
        if ((${#folder_slugs[@]} > 0)); then
            local idx
            for idx in "${!folder_slugs[@]}"; do
                local slug="${folder_slugs[$idx]}"
                [[ -z "$slug" ]] && continue
                local folder_name="${folder_displays[$idx]}"
                local folder_entry
                folder_entry=$(jq -n --arg name "$folder_name" --arg slug "$slug" '{name: $name, slug: $slug}' 2>/dev/null)
                if [[ -z "$folder_entry" ]]; then
                    success=false
                    continue
                fi
                local folder_entry_tmp
                folder_entry_tmp=$(mktemp -t n8n-folder-entry-XXXXXXXX.json)
                printf '%s\n' "$folder_entry" > "$folder_entry_tmp"
                if ! jq --slurpfile new "$folder_entry_tmp" '. + $new' "$folder_array_file" > "${folder_array_file}.tmp" 2>/dev/null; then
                    log WARN "Failed to append folder segment '$folder_name' for workflow '$workflow_name'."
                    rm -f "${folder_array_file}.tmp"
                    success=false
                    rm -f "$folder_entry_tmp"
                    continue
                fi
                mv "${folder_array_file}.tmp" "$folder_array_file"
                rm -f "$folder_entry_tmp"
            done
        fi

        local entry_err
        entry_err=$(mktemp -t n8n-folder-entry-XXXXXXXX.err)
        local entry_json
        entry_json=$(jq -n \
            --arg id "$workflow_id" \
            --arg name "$workflow_name" \
            --arg filename "$filename" \
            --arg relative "$relative_path" \
            --arg storage "$storage_path" \
            --arg display "$display_path" \
            --arg projectSlug "$entry_project_slug" \
            --arg projectName "$entry_project_display" \
            --arg manifestExisting "$manifest_existing_id" \
            --arg manifestOriginal "$manifest_original_id" \
            --arg manifestActual "$manifest_actual_id" \
            --arg manifestStrategy "$manifest_strategy" \
            --arg manifestWarning "$manifest_warning" \
            --arg manifestNote "$manifest_note" \
            --slurpfile folders "$folder_array_file" \
            'def blanknull($v): if $v == "" then null else $v end;
            {
                id: blanknull($id),
                manifestActualWorkflowId: blanknull($manifestActual),
                manifestExistingWorkflowId: blanknull($manifestExisting),
                manifestOriginalWorkflowId: blanknull($manifestOriginal),
                manifestResolutionStrategy: blanknull($manifestStrategy),
                manifestResolutionWarning: blanknull($manifestWarning),
                manifestResolutionNote: blanknull($manifestNote),
                name: $name,
                filename: $filename,
                relativePath: $relative,
                storagePath: $storage,
                displayPath: $display,
                project: {
                    id: null,
                    name: $projectName,
                    slug: $projectSlug
                },
                folders: ($folders[0] // [])
            }
            | with_entries(
                if (.key == "project" or .key == "folders") then .
                elif (.value == null or (.value | type) == "string" and (.value | length) == 0) then empty
                else . end
            )' 2>"$entry_err")
        local entry_status=$?

        if [[ $entry_status -ne 0 || -z "$entry_json" || "$entry_json" == "null" ]]; then
            if [[ -s "$entry_err" && "$verbose" == "true" ]]; then
                local entry_error_preview
                entry_error_preview=$(head -n 5 "$entry_err" 2>/dev/null)
                if [[ -n "$entry_error_preview" ]]; then
                    log DEBUG "jq error while building folder entry for '$workflow_name': $entry_error_preview"
                fi
            elif [[ "$verbose" == "true" ]]; then
                log DEBUG "Folder entry builder returned status=$entry_status payload='${entry_json:-<empty>}' for '$workflow_name'"
            fi
            log WARN "Unable to build folder entry payload for '$workflow_name'; skipping."
            rm -f "$entry_err"
            rm -f "$folder_array_file"
            success=false
            continue
        fi
        rm -f "$entry_err"

        local entry_temp
        entry_temp=$(mktemp -t n8n-folder-entry-XXXXXXXX.json)
        printf '%s\n' "$entry_json" > "$entry_temp"

        if ! jq --slurpfile new "$entry_temp" '. + $new' "$entries_file" > "${entries_file}.tmp" 2>/dev/null; then
            log ERROR "Failed to append folder entry for '$workflow_name' to manifest payload."
            rm -f "${entries_file}.tmp"
            rm -f "$entry_temp"
            rm -f "$folder_array_file"
            success=false
            continue
        fi

        mv "${entries_file}.tmp" "$entries_file"
        rm -f "$entry_temp"
        rm -f "$folder_array_file"
        processed=$((processed + 1))
    done < <(find "$source_dir" -type f -name "*.json" \
        ! -path "*/.credentials/*" \
        ! -path "*/archive/*" \
        ! -name "credentials.json" \
        ! -name "workflows.json" \
        ! -name ".n8n-folder-structure.json" -print0)

    if (( processed == 0 )); then
        rm -f "$entries_file"
        log ERROR "No workflow files found when collecting folder structure entries from $source_dir"
        return 1
    fi

    local payload_tmp
    payload_tmp=$(mktemp -t n8n-folder-payload-XXXXXXXX.json)
    if ! jq -n --slurpfile workflows "$entries_file" '{workflows: ($workflows[0] // [])}' > "$payload_tmp" 2>/dev/null; then
        log ERROR "Failed to compose folder structure payload."
        rm -f "$entries_file"
        rm -f "$payload_tmp"
        return 1
    fi

    mv "$payload_tmp" "$output_path"

    rm -f "$entries_file"

    if ! $success; then
        log WARN "Collected folder structure entries with warnings. Some workflows may lack folder metadata."
    fi

    log INFO "Collected folder structure entries from $source_dir"
    return 0
}

snapshot_existing_workflows() {
    local container_id="$1"
    local container_credentials_path="${2:-}"
    local keep_session_alive="${3:-false}"
    local snapshot_path=""
    existing_workflow_snapshot_source=""
    SNAPSHOT_EXISTING_WORKFLOWS_PATH=""
    local session_initialized=false

    if [[ -n "${n8n_base_url:-}" ]]; then
        if prepare_n8n_api_auth "$container_id" "$container_credentials_path"; then
            session_initialized=true
            local api_payload
            if api_payload=$(n8n_api_get_workflows); then
                local normalized_tmp
                normalized_tmp=$(mktemp -t n8n-existing-workflows-XXXXXXXX.json)
                if printf '%s' "$api_payload" | jq -c 'if type == "array" then . else (.data // []) end' > "$normalized_tmp" 2>/dev/null; then
                    snapshot_path="$normalized_tmp"
                    existing_workflow_snapshot_source="api"
                else
                    rm -f "$normalized_tmp"
                    log WARN "Unable to normalize workflow list from n8n API; falling back to other methods."
                fi
            else
                log WARN "Failed to retrieve workflow list via n8n API; attempting fallback methods."
            fi
            if [[ "$session_initialized" == "true" && "$keep_session_alive" != "true" ]]; then
                finalize_n8n_api_auth
                session_initialized=false
            fi
        else
            log DEBUG "n8n API authentication unavailable; attempting workflow snapshot fallback."
        fi
    fi

    if [[ -z "$snapshot_path" && -n "$container_id" ]]; then
        local container_tmp="/tmp/n8n-existing-workflows-$$.json"
        if dockExec "$container_id" "n8n export:workflow --all --output=$container_tmp" false; then
            local host_tmp
            host_tmp=$(mktemp -t n8n-existing-workflows-XXXXXXXX.json)
            if docker cp "${container_id}:${container_tmp}" "$host_tmp" >/dev/null 2>&1; then
                snapshot_path="$host_tmp"
                existing_workflow_snapshot_source="container"
            else
                rm -f "$host_tmp"
                log WARN "Unable to copy workflow snapshot from container; duplicate detection may be limited."
            fi
            dockExec "$container_id" "rm -f $container_tmp" false || true
        else
            log WARN "Failed to export workflows from container; proceeding without container snapshot."
        fi
    fi

    if [[ -n "$snapshot_path" ]]; then
        SNAPSHOT_EXISTING_WORKFLOWS_PATH="$snapshot_path"
        return 0
    fi

    log INFO "Workflow snapshot unavailable; proceeding without pre-import existence checks."
    if [[ "$session_initialized" == "true" && "$keep_session_alive" != "true" ]]; then
        finalize_n8n_api_auth
    elif [[ "$session_initialized" == "true" && "$keep_session_alive" == "true" ]]; then
        SNAPSHOT_EXISTING_WORKFLOWS_PATH=""
    fi
    return 1
}

match_existing_workflow() {
    local snapshot_path="$1"
    local staged_id="$2"
    local staged_instance="$3"
    local staged_name="$4"
    local staged_description="$5"
    local staged_storage_path="$6"
    local mapping_path="$7"

    local mapping_match_json=""
    if [[ -n "$mapping_path" && -f "$mapping_path" ]]; then
        mapping_match_json=$(jq -n \
            --arg path "$staged_storage_path" \
            --arg id "$staged_id" \
            --arg name "$staged_name" \
            --slurpfile mapping "$mapping_path" '
                def norm(v): (v // "") | ascii_downcase;
                ($mapping[0].workflows // []) as $workflows
                | (if ($path | length) > 0 then
                    $workflows | map(select(norm(.relativePath) == norm($path)))
                  else
                    $workflows
                  end) as $candidates
                | if ($id | length) > 0 then
                    ($candidates | map(select((.id // "") == $id)) | first // empty) as $id_hit
                    | if ($id_hit | type) == "object" and ($id_hit | length) > 0 then
                        {matchType: "id", workflow: $id_hit, storagePath: ($id_hit.relativePath // "")}
                      else empty end
                elif ($name | length) > 0 then
                    ($candidates | map(select(norm(.name) == norm($name))) | first // empty) as $name_hit
                    | if ($name_hit | type) == "object" and ($name_hit | length) > 0 then
                        {matchType: "name", workflow: $name_hit, storagePath: ($name_hit.relativePath // "")}
                      else empty end
                else empty end
            ' 2>/dev/null)

        if [[ -n "$mapping_match_json" && "$mapping_match_json" != "null" ]]; then
            printf '%s\n' "$mapping_match_json"
            return 0
        fi
    fi

    if [[ -z "$snapshot_path" || ! -f "$snapshot_path" ]]; then
        return 1
    fi

    local match_json=""
    if [[ -n "$staged_id" ]]; then
        match_json=$(jq -c --arg id "$staged_id" '
            (if type == "array" then . else [] end)
            | map(select(((.id // empty) | tostring) == $id))
            | first // empty
        ' "$snapshot_path" 2>/dev/null)
        if [[ -n "$match_json" && "$match_json" != "null" ]]; then
            jq -n --arg matchType "id" --argjson workflow "$match_json" --arg storage "${staged_storage_path:-}" '{matchType: $matchType, workflow: $workflow, storagePath: $storage}'
            return 0
        fi
    fi

    if [[ -n "$staged_instance" ]]; then
        match_json=$(jq -c --arg instance "$staged_instance" '
            (if type == "array" then . else [] end)
            | map(select((((.meta.instanceId // .meta.instanceID // empty) | tostring) == $instance)))
            | first // empty
        ' "$snapshot_path" 2>/dev/null)
        if [[ -n "$match_json" && "$match_json" != "null" ]]; then
            jq -n --arg matchType "instanceId" --argjson workflow "$match_json" --arg storage "${staged_storage_path:-}" '{matchType: $matchType, workflow: $workflow, storagePath: $storage}'
            return 0
        fi
    fi

    if [[ -n "$staged_name" ]]; then
        match_json=$(jq -c --arg name "$staged_name" '
            (if type == "array" then . else [] end)
            | map(select((.name // "") | ascii_downcase == ($name | ascii_downcase)))
            | first // empty
        ' "$snapshot_path" 2>/dev/null)
        if [[ -n "$match_json" && "$match_json" != "null" ]]; then
            jq -n --arg matchType "name" --argjson workflow "$match_json" --arg storage "${staged_storage_path:-}" '{matchType: $matchType, workflow: $workflow, storagePath: $storage}'
            return 0
        fi
    fi

    return 1
}

lookup_workflow_in_mapping() {
    local mapping_path="$1"
    local storage_path="$2"
    local workflow_name="$3"

    if [[ -z "$mapping_path" || ! -f "$mapping_path" ]]; then
        return 1
    fi

    jq -n \
        --arg path "${storage_path:-}" \
        --arg name "${workflow_name:-}" \
        --slurpfile mapping "$mapping_path" '
            def norm(v): (v // "" | ascii_downcase);
            def arr(x): if (x | type) == "array" then x else [] end;
            def as_entry(e; matchType; note): {
                matchType: matchType,
                workflow: {
                    id: (e.id // ""),
                    name: (e.name // ""),
                    relativePath: (e.relativePath // ""),
                    displayPath: (e.displayPath // ""),
                    project: (if ((e.project // null) | type) == "object" then e.project else null end),
                    folders: (if ((e.folders // []) | type) == "array" then e.folders else [] end),
                    updatedAt: (e.updatedAt // "")
                },
                storagePath: (e.relativePath // ""),
                displayPath: (e.displayPath // ""),
                resolutionNote: (note // null)
            };

            ($mapping[0].workflows // []) as $workflows
            | arr($workflows) as $entries
            | ($entries | map(select((.name // "") | length > 0))) as $named
            | ($entries | map(select((.relativePath // "") | length > 0))) as $pathable
            | ($path | length) as $pathLen
            | ($name | length) as $nameLen

            | (if $pathLen > 0 then
                    $pathable
                    | map(select(norm(.relativePath) == norm($path)))
                    | sort_by(.updatedAt // "")
                else [] end) as $pathMatches
            | (if $nameLen > 0 then
                    $named
                    | map(select(norm(.name) == norm($name)))
                else [] end) as $nameMatches

            | if ($pathMatches | length) == 1 then
                as_entry($pathMatches[0]; "path"; null)
            elif ($pathMatches | length) > 1 then
                as_entry((($pathMatches | sort_by(.updatedAt // "")) | last); "path-newest"; "multiple path matches resolved via newest updatedAt")
            elif ($nameMatches | length) == 1 then
                as_entry($nameMatches[0]; "name"; null)
            elif ($nameMatches | length) > 1 then
                ($nameMatches
                 | group_by(norm(.relativePath // ""))
                 | map(select(length > 0))
                 | map({path: (.[0].relativePath // ""), entries: .})) as $byPath
                | ($byPath | length) as $distinctPaths
                | if $distinctPaths == 1 then
                    as_entry((($nameMatches | sort_by(.updatedAt // "")) | last); "name-newest"; "multiple name matches sharing relativePath resolved via newest updatedAt")
                  else empty end
            else empty end
    ' 2>/dev/null
}

append_sanitized_note() {
    local existing="${1:-}"
    local addition="${2:-}"

    if [[ -z "$addition" ]]; then
        printf '%s\n' "$existing"
        return 0
    fi

    if [[ -z "$existing" ]]; then
        printf '%s\n' "$addition"
        return 0
    fi

    local needle=";$addition;"
    local haystack=";$existing;"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf '%s\n' "$existing"
        return 0
    fi

    printf '%s\n' "${existing};${addition}"
    return 0
}

lookup_workflow_path_by_id() {
    local mapping_path="$1"
    local workflow_id="$2"

    if [[ -z "$mapping_path" || ! -f "$mapping_path" || -z "$workflow_id" ]]; then
        return 1
    fi

    local lookup_json
    lookup_json=$(jq -n \
        --arg id "$workflow_id" \
        --slurpfile mapping "$mapping_path" '
            ($mapping[0].workflows // [])
            | map(select((.id // "") == $id))
            | first // empty
            | if (type == "object") then
                {found: true, path: ((.relativePath // .storagePath // "") | tostring)}
              else {found: false, path: ""} end
        ' 2>/dev/null)

    if [[ -z "$lookup_json" ]]; then
        return 1
    fi

    local found_flag
    found_flag=$(printf '%s' "$lookup_json" | jq -r '.found // false' 2>/dev/null)
    if [[ "$found_flag" != "true" ]]; then
        return 1
    fi

    local relpath
    relpath=$(printf '%s' "$lookup_json" | jq -r '.path // ""' 2>/dev/null)
    if [[ "$relpath" == "null" ]]; then
        relpath=""
    fi

    printf '%s\n' "$relpath"
    return 0
}


normalize_entry_identifier() {
    local value="${1:-}"
    if [[ -z "$value" || "$value" == "null" ]]; then
        printf ''
        return
    fi

    value="$(printf '%s' "$value" | tr -d '\r\n\t')"
    value="$(printf '%s' "$value" | sed 's/^[[:space:]]\+//;s/[[:space:]]\+$//')"

    case "$value" in
        0)
            printf ''
            return
            ;;
    esac

    local lowered
    lowered=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
    if [[ "$lowered" == "root" ]]; then
        printf ''
        return
    fi

    printf '%s' "$value"
}

build_project_lookup_tables() {
    local projects_json="$1"
    local verbose_flag="$2"
    local -n out_project_name_map="$3"
    local -n out_project_slug_map="$4"
    local -n out_project_id_map="$5"
    local -n out_default_project_id="$6"
    local -n out_personal_project_id="$7"

    out_project_name_map=()
    out_project_slug_map=()
    out_project_id_map=()
    out_default_project_id=""
    out_personal_project_id=""

    local project_entries_file
    project_entries_file=$(mktemp -t n8n-project-entries-XXXXXXXX.json)
    local project_entries_err
    project_entries_err=$(mktemp -t n8n-project-entries-err-XXXXXXXX.log)

    if ! printf '%s' "$projects_json" | jq -c 'if type == "array" then .[] else (.data // [])[] end' > "$project_entries_file" 2>"$project_entries_err"; then
        local jq_error
        jq_error=$(cat "$project_entries_err" 2>/dev/null)
        log ERROR "Failed to parse projects payload while preparing lookup tables."
        if [[ -n "$jq_error" ]]; then
            log DEBUG "jq error (projects): $jq_error"
        fi
        if [[ "$verbose_flag" == "true" ]]; then
            local projects_preview
            projects_preview=$(printf '%s' "$projects_json" | head -c 400 2>/dev/null)
            log DEBUG "Projects payload preview: ${projects_preview:-<empty>}"
        fi
        rm -f "$project_entries_file" "$project_entries_err"
        return 1
    fi
    rm -f "$project_entries_err"

    local project_entry_count
    project_entry_count=$(wc -l < "$project_entries_file" 2>/dev/null | tr -d '[:space:]')
    log DEBUG "Prepared ${project_entry_count:-0} project entr(y/ies) from API payload."

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
        if [[ -n "$key" ]]; then
            out_project_name_map["$key"]="$pid"
        fi

        local pslug
        pslug=$(printf '%s' "$project_entry" | jq -r '.slug // empty' 2>/dev/null)
        if [[ -z "$pslug" || "$pslug" == "null" ]]; then
            pslug=$(sanitize_slug "$pname")
        fi
        if [[ -n "$pslug" ]]; then
            local pslug_lower
            pslug_lower=$(printf '%s' "$pslug" | tr '[:upper:]' '[:lower:]')
            if [[ -n "$pslug_lower" ]]; then
                out_project_slug_map["$pslug_lower"]="$pid"
            fi
        fi

        local ptype
        ptype=$(printf '%s' "$project_entry" | jq -r '.type // empty' 2>/dev/null)
        if [[ -z "$out_personal_project_id" ]]; then
            if [[ "$ptype" == "personal" ]]; then
                out_personal_project_id="$pid"
            elif [[ "$key" == "personal" ]]; then
                out_personal_project_id="$pid"
            fi
        fi

        out_project_id_map["$pid"]="$pname"
        if [[ -z "$out_default_project_id" ]]; then
            out_default_project_id="$pid"
        fi
    done < "$project_entries_file"
    rm -f "$project_entries_file"

    if [[ -n "$out_personal_project_id" ]]; then
        out_default_project_id="$out_personal_project_id"
        out_project_name_map["personal"]="$out_personal_project_id"
        out_project_slug_map["personal"]="$out_personal_project_id"
    fi

    if [[ -z "$out_default_project_id" ]]; then
        log ERROR "No projects available in n8n instance; cannot restore folder structure."
        return 1
    fi

    return 0
}

build_folder_lookup_tables() {
    local folders_json="$1"
    local verbose_flag="$2"
    local -n out_folder_parent_lookup="$3"
    local -n out_folder_project_lookup="$4"
    local -n out_folder_slug_by_id="$5"
    local -n out_folder_name_by_id="$6"
    local -n out_folder_slug_lookup="$7"
    local -n out_folder_name_lookup="$8"
    local -n out_folder_path_lookup="$9"

    out_folder_parent_lookup=()
    out_folder_project_lookup=()
    out_folder_slug_by_id=()
    out_folder_name_by_id=()
    out_folder_slug_lookup=()
    out_folder_name_lookup=()
    out_folder_path_lookup=()

    local folder_entries_file
    folder_entries_file=$(mktemp -t n8n-folder-entries-XXXXXXXX.json)
    local folder_entries_err
    folder_entries_err=$(mktemp -t n8n-folder-entries-err-XXXXXXXX.log)

    if ! printf '%s' "$folders_json" | jq -c 'if type == "array" then .[] else (.data // [])[] end' > "$folder_entries_file" 2>"$folder_entries_err"; then
        local jq_error
        jq_error=$(cat "$folder_entries_err" 2>/dev/null)
        log ERROR "Failed to parse folders payload while preparing lookup tables."
        if [[ -n "$jq_error" ]]; then
            log DEBUG "jq error (folders): $jq_error"
        fi
        if [[ "$verbose_flag" == "true" ]]; then
            local folders_preview
            folders_preview=$(printf '%s' "$folders_json" | head -c 400 2>/dev/null)
            log DEBUG "Folders payload preview: ${folders_preview:-<empty>}"
        fi
        rm -f "$folder_entries_file" "$folder_entries_err"
        return 1
    fi
    rm -f "$folder_entries_err"

    local folder_entry_count
    folder_entry_count=$(wc -l < "$folder_entries_file" 2>/dev/null | tr -d '[:space:]')
    if [[ "$verbose_flag" == "true" ]]; then
        log DEBUG "Loaded ${folder_entry_count:-0} existing folder(s) from n8n for restore context."
    fi

    declare -A folder_duplicate_warned=()

    while IFS= read -r folder_entry; do
        local fid
        fid=$(printf '%s' "$folder_entry" | jq -r '.id // empty' 2>/dev/null)
        local fname
        fname=$(printf '%s' "$folder_entry" | jq -r '.name // empty' 2>/dev/null)
        local fproject
        fproject=$(printf '%s' "$folder_entry" | jq -r '.projectId // (.homeProject.id // .homeProjectId // empty)' 2>/dev/null)
        fproject=$(normalize_entry_identifier "$fproject")
        if [[ -z "$fid" || -z "$fproject" ]]; then
            if [[ -n "$fid" && "$verbose_flag" == "true" ]]; then
                log DEBUG "Skipping folder '$fid' due to missing project reference in API payload."
            fi
            continue
        fi

        local parent
        parent=$(normalize_entry_identifier "$(printf '%s' "$folder_entry" | jq -r '.parentFolderId // (.parentFolder.id // .parentFolderId // empty)' 2>/dev/null)")
        local parent_key="${parent:-root}"
        local folder_slug
        folder_slug=$(sanitize_slug "$fname")

        out_folder_parent_lookup["$fid"]="$parent_key"
        out_folder_project_lookup["$fid"]="$fproject"
        out_folder_slug_by_id["$fid"]="$folder_slug"
        out_folder_name_by_id["$fid"]="$fname"

        local folder_slug_lower
        folder_slug_lower=$(printf '%s' "$folder_slug" | tr '[:upper:]' '[:lower:]')
        local folder_name_lower
        folder_name_lower=$(printf '%s' "$fname" | tr '[:upper:]' '[:lower:]')

        if [[ -n "$folder_slug_lower" ]]; then
            local slug_key="$fproject|${parent_key}|$folder_slug_lower"
            local existing_slug_id="${out_folder_slug_lookup[$slug_key]:-}"
            if [[ -n "$existing_slug_id" && "$existing_slug_id" != "$fid" ]]; then
                local warn_key="slug|$slug_key|$existing_slug_id"
                if [[ -z "${folder_duplicate_warned[$warn_key]+set}" ]]; then
                    log WARN "Multiple folders share slug '${folder_slug_lower:-<empty>}' under parent '${parent_key:-root}' in project '$fproject' (IDs: $existing_slug_id, $fid)."
                    folder_duplicate_warned[$warn_key]=1
                fi
            else
                out_folder_slug_lookup[$slug_key]="$fid"
            fi
        fi

        if [[ -n "$folder_name_lower" ]]; then
            local name_key="$fproject|${parent_key}|$folder_name_lower"
            local existing_name_id="${out_folder_name_lookup[$name_key]:-}"
            if [[ -n "$existing_name_id" && "$existing_name_id" != "$fid" ]]; then
                local warn_key="name|$name_key|$existing_name_id"
                if [[ -z "${folder_duplicate_warned[$warn_key]+set}" ]]; then
                    log WARN "Multiple folders share name '${folder_name_lower:-<empty>}' under parent '${parent_key:-root}' in project '$fproject' (IDs: $existing_name_id, $fid)."
                    folder_duplicate_warned[$warn_key]=1
                fi
            else
                out_folder_name_lookup[$name_key]="$fid"
            fi
        fi
    done < "$folder_entries_file"
    rm -f "$folder_entries_file"

    for fid in "${!out_folder_project_lookup[@]}"; do
        local project_ref="${out_folder_project_lookup[$fid]:-}"
        [[ -z "$project_ref" ]] && continue

        local current="$fid"
        local guard=0
        local -a path_segments=()
        while [[ -n "$current" && "$current" != "root" && $guard -lt 200 ]]; do
            local segment_slug="${out_folder_slug_by_id[$current]:-}"
            if [[ -z "$segment_slug" ]]; then
                segment_slug=$(sanitize_slug "${out_folder_name_by_id[$current]:-folder}")
            fi
            if [[ -z "$segment_slug" ]]; then
                segment_slug="folder"
            fi
            local segment_slug_lower
            segment_slug_lower=$(printf '%s' "$segment_slug" | tr '[:upper:]' '[:lower:]')
            path_segments=("$segment_slug_lower" "${path_segments[@]}")

            local parent_ref="${out_folder_parent_lookup[$current]:-root}"
            if [[ -z "$parent_ref" || "$parent_ref" == "root" ]]; then
                current=""
            else
                current="$parent_ref"
            fi
            guard=$((guard + 1))
        done

        if ((${#path_segments[@]} == 0)); then
            continue
        fi

        local slug_path
        slug_path=$(IFS=/; printf '%s' "${path_segments[*]}")
        local path_key="$project_ref|$slug_path"
        local existing_path_id="${out_folder_path_lookup[$path_key]:-}"
        if [[ -n "$existing_path_id" && "$existing_path_id" != "$fid" ]]; then
            local warn_key="path|$path_key|$existing_path_id"
            if [[ -z "${folder_duplicate_warned[$warn_key]+set}" ]]; then
                log WARN "Multiple folders resolve to slug path '$slug_path' in project '$project_ref' (IDs: $existing_path_id, $fid)."
                folder_duplicate_warned[$warn_key]=1
            fi
            continue
        fi

        out_folder_path_lookup[$path_key]="$fid"
    done

    return 0
}

build_workflow_lookup_tables() {
    local workflows_json="$1"
    local verbose_flag="$2"
    local -n out_workflow_version_lookup="$3"
    local -n out_workflow_parent_lookup="$4"
    local -n out_workflow_project_lookup="$5"
    local -n out_workflow_name_lookup="$6"
    local -n out_workflow_name_conflicts="$7"

    out_workflow_version_lookup=()
    out_workflow_parent_lookup=()
    out_workflow_project_lookup=()
    out_workflow_name_lookup=()
    out_workflow_name_conflicts=()

    local workflow_entries_file
    workflow_entries_file=$(mktemp -t n8n-workflow-entries-XXXXXXXX.json)
    local workflow_entries_err
    workflow_entries_err=$(mktemp -t n8n-workflow-entries-err-XXXXXXXX.log)

    if ! printf '%s' "$workflows_json" | jq -c 'if type == "array" then .[] else (.data // [])[] end' > "$workflow_entries_file" 2>"$workflow_entries_err"; then
        local jq_error
        jq_error=$(cat "$workflow_entries_err" 2>/dev/null)
        log ERROR "Failed to parse workflows payload while preparing lookup tables."
        if [[ -n "$jq_error" ]]; then
            log DEBUG "jq error (workflows): $jq_error"
        fi
        if [[ "$verbose_flag" == "true" ]]; then
            local workflows_preview
            workflows_preview=$(printf '%s' "$workflows_json" | head -c 400 2>/dev/null)
            log DEBUG "Workflows payload preview: ${workflows_preview:-<empty>}"
        fi
        rm -f "$workflow_entries_file" "$workflow_entries_err"
        return 1
    fi
    rm -f "$workflow_entries_err"

    local workflow_entry_count
    workflow_entry_count=$(wc -l < "$workflow_entries_file" 2>/dev/null | tr -d '[:space:]')
    if [[ "$verbose_flag" == "true" ]]; then
        log DEBUG "Loaded ${workflow_entry_count:-0} existing workflow(s) from n8n for restore context."
    fi

    while IFS= read -r workflow_entry; do
        local wid
        wid=$(printf '%s' "$workflow_entry" | jq -r '.id // empty' 2>/dev/null)
        if [[ -z "$wid" ]]; then
            continue
        fi

        local version_id
        version_id=$(printf '%s' "$workflow_entry" | jq -r '.versionId // (.version.id // empty)' 2>/dev/null)
        if [[ "$version_id" == "null" ]]; then
            version_id=""
        fi

        local wproject
        wproject=$(normalize_entry_identifier "$(printf '%s' "$workflow_entry" | jq -r '.homeProject.id // .homeProjectId // empty' 2>/dev/null)")
        local wparent
        wparent=$(normalize_entry_identifier "$(printf '%s' "$workflow_entry" | jq -r '.parentFolderId // (.parentFolder.id // empty)' 2>/dev/null)")

        out_workflow_version_lookup["$wid"]="$version_id"
        out_workflow_parent_lookup["$wid"]="$wparent"
        out_workflow_project_lookup["$wid"]="$wproject"

        local wname_lower
        wname_lower=$(printf '%s' "$workflow_entry" | jq -r '.name // empty' 2>/dev/null | tr '[:upper:]' '[:lower:]')
        if [[ -n "$wname_lower" && "$wname_lower" != "null" && -n "$wproject" ]]; then
            wname_lower=$(printf '%s' "$wname_lower" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
            if [[ -n "$wname_lower" ]]; then
                local name_key="$wproject|$wname_lower"
                if [[ -n "${out_workflow_name_lookup[$name_key]+set}" && "${out_workflow_name_lookup[$name_key]}" != "$wid" ]]; then
                    out_workflow_name_conflicts["$name_key"]=1
                else
                    out_workflow_name_lookup["$name_key"]="$wid"
                fi
            fi
        fi
    done < "$workflow_entries_file"
    rm -f "$workflow_entries_file"

    return 0
}

append_assignment_audit_record() {
    local output_path="$1"
    local workflow_id="$2"
    local workflow_name="$3"
    local project_id="$4"
    local folder_id="$5"
    local display_path="$6"
    local version_id="$7"
    local version_mode="$8"
    local status="$9"
    local note="${10:-}"

    if [[ -z "$output_path" ]]; then
        return 0
    fi

    local record
    record=$(jq -n \
        --arg workflowId "$workflow_id" \
        --arg workflowName "$workflow_name" \
        --arg projectId "$project_id" \
        --arg folderId "${folder_id:-}" \
        --arg displayPath "${display_path:-}" \
        --arg status "$status" \
        --arg versionId "${version_id:-}" \
        --arg versionMode "$version_mode" \
        --arg note "${note:-}" \
        '{
            workflowId: $workflowId,
            workflowName: $workflowName,
            projectId: $projectId,
            folderId: (if ($folderId // "") == "" then null else $folderId end),
            displayPath: $displayPath,
            status: $status,
            version: (if $versionMode == "string" then {
                    mode: "exact",
                    value: (if ($versionId // "") == "" then null else $versionId end)
                } elif $versionMode == "null" then {
                    mode: "null"
                } else {
                    mode: $versionMode,
                    value: (if ($versionId // "") == "" then null else $versionId end)
                } end),
            note: (if ($note // "") == "" then null else $note end)
        }'
    )

    printf '%s\n' "$record" >> "$output_path"
    return 0
}

apply_directory_structure_entries() {
    local entries_path="$1"
    local container_id="$2"
    local is_dry_run="$3"
    local container_credentials_path="$4"

    if [[ "$is_dry_run" == "true" ]]; then
        log DRYRUN "Would apply folder structure using entries file: $entries_path"
        return 0
    fi

    if [[ -z "$entries_path" || ! -f "$entries_path" ]]; then
        log WARN "Folder structure entries file not found: ${entries_path:-<empty>}"
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

    if [[ "$verbose" == "true" ]]; then
        local projects_debug_file
        projects_debug_file=$(mktemp -t n8n-restore-projects-XXXXXXXX.json)
        printf '%s' "$projects_json" > "$projects_debug_file"
        log DEBUG "Saved projects API payload to $projects_debug_file"
    fi

    local folders_json
    if ! folders_json=$(n8n_api_get_folders); then
        if [[ "${N8N_API_LAST_STATUS:-}" == "404" ]]; then
            log WARN "Folder structure not supported by this n8n version (HTTP 404). Skipping folder restoration."
            finalize_n8n_api_auth
            return 0
        fi
        finalize_n8n_api_auth
        log ERROR "Failed to fetch folders from n8n API."
        return 1
    fi

    if [[ "$verbose" == "true" ]]; then
        local folders_debug_file
        folders_debug_file=$(mktemp -t n8n-restore-folders-XXXXXXXX.json)
        printf '%s' "$folders_json" > "$folders_debug_file"
        log DEBUG "Saved folders API payload to $folders_debug_file"
    fi

    local workflows_json
    if ! workflows_json=$(n8n_api_get_workflows); then
        finalize_n8n_api_auth
        log ERROR "Failed to fetch workflows from n8n API."
        return 1
    fi

    if [[ "$verbose" == "true" ]]; then
        local workflows_debug_file
        workflows_debug_file=$(mktemp -t n8n-restore-workflows-XXXXXXXX.json)
        printf '%s' "$workflows_json" > "$workflows_debug_file"
        log DEBUG "Saved workflows API payload to $workflows_debug_file"
    fi

    declare -A project_name_map=()
    declare -A project_slug_map=()
    declare -A project_id_map=()
    local default_project_id=""
    local personal_project_id=""

    if ! build_project_lookup_tables "$projects_json" "$verbose" project_name_map project_slug_map project_id_map default_project_id personal_project_id; then
        finalize_n8n_api_auth
        return 1
    fi

    if [[ "$verbose" == "true" && -n "$personal_project_id" ]]; then
        log DEBUG "Detected personal project ID '$personal_project_id' while preparing restoral lookups."
    fi

    local configured_project_id=""
    local configured_project_display=""
    if [[ -n "${project_name:-}" && "${project_name}" != "null" ]]; then
        local configured_name_lower
        configured_name_lower=$(printf '%s' "${project_name}" | tr '[:upper:]' '[:lower:]')
        if [[ -n "${project_name_map["$configured_name_lower"]:-}" ]]; then
            configured_project_id="${project_name_map["$configured_name_lower"]}"
        else
            local configured_slug
            configured_slug=$(sanitize_slug "${project_name}")
            if [[ -n "$configured_slug" ]]; then
                local configured_slug_lower
                configured_slug_lower=$(printf '%s' "$configured_slug" | tr '[:upper:]' '[:lower:]')
                if [[ -n "${project_slug_map["$configured_slug_lower"]:-}" ]]; then
                    configured_project_id="${project_slug_map["$configured_slug_lower"]}"
                fi
            fi
        fi
        if [[ -z "$configured_project_id" && -n "${project_id_map["${project_name}"]:-}" ]]; then
            configured_project_id="${project_name}"
        fi
        if [[ -n "$configured_project_id" ]]; then
            configured_project_display="${project_id_map["$configured_project_id"]:-${project_name}}"
            default_project_id="$configured_project_id"
            log INFO "Using configured default project '${configured_project_display}' for restore operations."
        else
            local default_display="${project_id_map["$default_project_id"]:-Personal}"
            log WARN "Configured project '${project_name}' was not found in the target n8n instance; using default project '${default_display}'."
        fi
    fi

    local fallback_project_id="$default_project_id"

    declare -A folder_parent_lookup=()
    declare -A folder_project_lookup=()
    declare -A folder_slug_by_id=()
    declare -A folder_name_by_id=()
    declare -A folder_slug_lookup=()
    declare -A folder_name_lookup=()
    declare -A folder_path_lookup=()

    if ! build_folder_lookup_tables "$folders_json" "$verbose" folder_parent_lookup folder_project_lookup folder_slug_by_id folder_name_by_id folder_slug_lookup folder_name_lookup folder_path_lookup; then
        finalize_n8n_api_auth
        return 1
    fi

    declare -A workflow_version_lookup=()
    declare -A workflow_parent_lookup=()
    declare -A workflow_project_lookup=()
    declare -A workflow_name_lookup=()
    declare -A workflow_name_conflicts=()

    if ! build_workflow_lookup_tables "$workflows_json" "$verbose" workflow_version_lookup workflow_parent_lookup workflow_project_lookup workflow_name_lookup workflow_name_conflicts; then
        finalize_n8n_api_auth
        return 1
    fi

    local total_count
    total_count=$(jq -r '.workflows | length' "$entries_path" 2>/dev/null || echo 0)
    if [[ "$total_count" -eq 0 ]]; then
        finalize_n8n_api_auth
        log INFO "Folder structure entries empty; nothing to apply."
        return 0
    fi

    local moved_count=0
    local overall_success=true
    local project_created_count=0
    local folder_created_count=0
    local folder_moved_count=0
    local workflow_assignment_count=0
    local license_feature_blocked=false
    local license_notice_emitted=false

    local entry_records_file
    entry_records_file=$(mktemp -t n8n-folder-entries-XXXXXXXX.json)
    local entry_records_err
    entry_records_err=$(mktemp -t n8n-folder-entries-err-XXXXXXXX.log)
    if ! jq -c '.workflows[]' "$entries_path" > "$entry_records_file" 2>"$entry_records_err"; then
        local jq_error
        jq_error=$(cat "$entry_records_err" 2>/dev/null)
        log ERROR "Failed to parse folder structure entries data."
        if [[ -n "$jq_error" ]]; then
            log DEBUG "jq error (entries): $jq_error"
        fi
        if [[ "$verbose" == "true" ]]; then
            local entries_preview
            entries_preview=$(head -c 400 "$entries_path" 2>/dev/null)
            log DEBUG "Entries payload preview: ${entries_preview:-<empty>}"
        fi
        rm -f "$entry_records_file" "$entry_records_err"
        finalize_n8n_api_auth
        return 1
    fi
    rm -f "$entry_records_err"

    local entry_record_count
    entry_record_count=$(wc -l < "$entry_records_file" 2>/dev/null | tr -d '[:space:]')
    log INFO "Assigning ${entry_record_count:-0} imported workflow(s) to target folders..."

    local assignment_tracking_file
    assignment_tracking_file=$(mktemp -t n8n-workflow-assignment-XXXXXXXX.ndjson)
    local assignment_tracking_count=0

    while IFS= read -r entry; do
        # Extract workflow ID from manifest - this is the ID in the imported file
        local workflow_id=""
        workflow_id=$(printf '%s' "$entry" | jq -r '.id // empty' 2>/dev/null)
        
        # Extract workflow identification info from manifest entry
        local manifest_existing_id
        manifest_existing_id=$(printf '%s' "$entry" | jq -r '.existingWorkflowId // empty' 2>/dev/null)

        local workflow_name
        workflow_name=$(printf '%s' "$entry" | jq -r '.name // "Workflow"' 2>/dev/null)
        local workflow_name_lower
        workflow_name_lower=$(printf '%s' "$workflow_name" | tr '[:upper:]' '[:lower:]')
        workflow_name_lower=$(printf '%s' "$workflow_name_lower" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
        local display_path
        display_path=$(printf '%s' "$entry" | jq -r '.displayPath // empty' 2>/dev/null)

        local storage_path
        storage_path=$(printf '%s' "$entry" | jq -r '.storagePath // empty' 2>/dev/null)
        local relative_path_entry
        relative_path_entry=$(printf '%s' "$entry" | jq -r '.relativePath // empty' 2>/dev/null)
        
        # Note: We don't filter by GITHUB_PATH here because workflows in the manifest
        # already passed that filter during staging. The manifest only contains workflows
        # that should be processed for the current restore operation.

        local project_name
        project_name=$(printf '%s' "$entry" | jq -r '.project.name // empty' 2>/dev/null)
        local project_id_hint
        project_id_hint=$(normalize_entry_identifier "$(printf '%s' "$entry" | jq -r '.project.id // empty' 2>/dev/null)")
        local project_slug
        project_slug=$(printf '%s' "$entry" | jq -r '.project.slug // empty' 2>/dev/null)

        if [[ -z "$project_name" || "$project_name" == "null" ]]; then
            project_name=$(unslug_to_title "$project_slug")
        fi

        local target_project_id=""

        if [[ -n "$project_slug" && "$project_slug" != "null" ]]; then
            local project_slug_key
            project_slug_key=$(printf '%s' "$project_slug" | tr '[:upper:]' '[:lower:]')
            if [[ -n "${project_slug_map[$project_slug_key]+set}" ]]; then
                target_project_id="${project_slug_map[$project_slug_key]}"
            fi
        fi

        if [[ -z "$target_project_id" && -n "$project_id_hint" && -n "${project_id_map[$project_id_hint]+set}" ]]; then
            target_project_id="$project_id_hint"
        fi

        if [[ -z "$target_project_id" && -n "$project_name" ]]; then
            local project_key
            project_key=$(printf '%s' "$project_name" | tr '[:upper:]' '[:lower:]')
            if [[ -n "${project_name_map[$project_key]+set}" ]]; then
                target_project_id="${project_name_map[$project_key]}"
            fi
        fi

        if [[ -z "$target_project_id" ]]; then
            target_project_id="$fallback_project_id"
            local fallback_display="${project_id_map["$target_project_id"]:-Personal}"
            local fallback_display_lower=$(printf '%s' "$fallback_display" | tr '[:upper:]' '[:lower:]')
            local fallback_slug_lower=$(printf '%s' "$(sanitize_slug "$fallback_display")" | tr '[:upper:]' '[:lower:]')
            local project_name_lower=""
            if [[ -n "$project_name" && "$project_name" != "null" ]]; then
                project_name_lower=$(printf '%s' "$project_name" | tr '[:upper:]' '[:lower:]')
            fi
            local project_slug_lower=""
            if [[ -n "$project_slug" && "$project_slug" != "null" ]]; then
                project_slug_lower=$(printf '%s' "$project_slug" | tr '[:upper:]' '[:lower:]')
            fi
            if [[ -n "$project_name_lower" && "$project_name_lower" != "$fallback_display_lower" ]]; then
                log INFO "Project specification '$project_name' not recognized; defaulting to project '$fallback_display' for workflow '$workflow_name'."
            elif [[ -n "$project_slug_lower" && "$project_slug_lower" != "$fallback_slug_lower" ]]; then
                log INFO "Project slug '$project_slug' not recognized; defaulting to project '$fallback_display' for workflow '$workflow_name'."
            fi
        fi

        # Validate workflow ID exists in current n8n instance
        # If the ID from manifest doesn't exist, try name-based lookup as fallback
        if [[ -n "$workflow_id" && -z "${workflow_project_lookup[$workflow_id]+set}" ]]; then
            if [[ "$verbose" == "true" ]]; then
                log DEBUG "Workflow ID '$workflow_id' from manifest not found in n8n; attempting name-based lookup for '$workflow_name'"
            fi
            workflow_id=""
        fi
        
        # Fallback to name-based lookup if ID is not available or not found
        if [[ -z "$workflow_id" && -n "$workflow_name_lower" ]]; then
            local name_key="${target_project_id}|$workflow_name_lower"
            if [[ -n "${workflow_name_lookup[$name_key]+set}" && -z "${workflow_name_conflicts[$name_key]+set}" ]]; then
                workflow_id="${workflow_name_lookup[$name_key]}"
                if [[ "$verbose" == "true" ]]; then
                    log DEBUG "Resolved workflow '$workflow_name' via name lookup in project '${project_id_map[$target_project_id]:-Default}' (ID: $workflow_id)."
                fi
            elif [[ -n "${workflow_name_conflicts[$name_key]+set}" ]]; then
                log WARN "Multiple workflows named '$workflow_name' exist in target project; unable to determine correct workflow for folder assignment."
                workflow_id=""
            else
                # Workflow not found by name - may not have been imported yet or import failed
                if [[ "$verbose" == "true" ]]; then
                    log DEBUG "Workflow '$workflow_name' not found in project '${project_id_map[$target_project_id]:-Default}' - may not have been imported."
                fi
                workflow_id=""
            fi
        fi

        local -a folder_entries=()
        while IFS= read -r folder_obj; do
            if [[ -n "$folder_obj" && "$folder_obj" != "null" ]]; then
                folder_entries+=("$folder_obj")
            fi
        done < <(printf '%s' "$entry" | jq -c '.folders[]?' 2>/dev/null)

    local parent_folder_id=""
    local current_slug_path=""
    local folder_failure=false
    local folder_license_block=false

        for folder_entry in "${folder_entries[@]}"; do
            local folder_name
            folder_name=$(printf '%s' "$folder_entry" | jq -r '.name // empty' 2>/dev/null)
            local folder_slug
            folder_slug=$(printf '%s' "$folder_entry" | jq -r '.slug // empty' 2>/dev/null)

            if [[ -z "$folder_name" || "$folder_name" == "null" ]]; then
                folder_name=$(unslug_to_title "$folder_slug")
            fi

            if [[ -z "$folder_slug" || "$folder_slug" == "null" ]]; then
                folder_slug=$(sanitize_slug "$folder_name")
            fi

            local parent_key="${parent_folder_id:-root}"
            
            # For lookups, we need lowercase versions for case-insensitive matching
            local folder_name_lower=""
            [[ -n "$folder_name" && "$folder_name" != "null" ]] && folder_name_lower=$(printf '%s' "$folder_name" | tr '[:upper:]' '[:lower:]')
            local folder_slug_lower=""
            [[ -n "$folder_slug" && "$folder_slug" != "null" ]] && folder_slug_lower=$(printf '%s' "$folder_slug" | tr '[:upper:]' '[:lower:]')

            if [[ -z "$folder_slug_lower" ]]; then
                folder_slug_lower=$(printf '%s' "$(sanitize_slug "$folder_name")" | tr '[:upper:]' '[:lower:]')
            fi

            # Build path using actual folder NAME (preserving original casing and spaces)
            # This keeps "Asana 3" as "Asana 3", not "asana 3" or "asana_3"
            local candidate_path=""
            if [[ -n "$folder_name" ]]; then
                if [[ -z "$current_slug_path" ]]; then
                    candidate_path="$folder_name"
                else
                    candidate_path="$current_slug_path/$folder_name"
                fi
            fi

            local existing_folder_id=""
            if [[ -n "$candidate_path" && -n "${folder_path_lookup["$target_project_id|$candidate_path"]+set}" ]]; then
                existing_folder_id="${folder_path_lookup["$target_project_id|$candidate_path"]}"
                if [[ "$verbose" == "true" ]]; then
                    log DEBUG "Reusing existing folder at path '$candidate_path' (ID: $existing_folder_id) in project '${target_project_id}'"
                fi
            fi

            if [[ -z "$existing_folder_id" ]]; then
                local slug_lookup_key="$target_project_id|${parent_key}|$folder_slug_lower"
                if [[ -n "${folder_slug_lookup["$slug_lookup_key"]+set}" ]]; then
                    existing_folder_id="${folder_slug_lookup["$slug_lookup_key"]}"
                    if [[ "$verbose" == "true" ]]; then
                        log DEBUG "Matched existing folder '$folder_name' under parent '${parent_key:-root}' (ID: $existing_folder_id)"
                    fi
                fi
            fi

            if [[ -z "$existing_folder_id" ]]; then
                local name_lookup_key="$target_project_id|${parent_key}|$folder_name_lower"
                if [[ -n "${folder_name_lookup["$name_lookup_key"]+set}" ]]; then
                    existing_folder_id="${folder_name_lookup["$name_lookup_key"]}"
                    if [[ "$verbose" == "true" ]]; then
                        log DEBUG "Matched folder by name lookup '${folder_name_lower:-<empty>}' under parent '${parent_key:-root}' (ID: $existing_folder_id)."
                    fi
                fi
            fi

            if [[ -z "$existing_folder_id" ]]; then
                local parent_match="${parent_folder_id:-root}"
                local candidate_match=""
                for existing_id in "${!folder_parent_lookup[@]}"; do
                    [[ -z "$existing_id" ]] && continue
                    if [[ "${folder_project_lookup[$existing_id]:-}" != "$target_project_id" ]]; then
                        continue
                    fi
                    local existing_parent="${folder_parent_lookup[$existing_id]:-root}"
                    if [[ "$parent_match" == "root" ]]; then
                        if [[ -n "$parent_folder_id" ]]; then
                            if [[ "$existing_parent" != "$parent_folder_id" ]]; then
                                continue
                            fi
                        else
                            if [[ -n "$existing_parent" && "$existing_parent" != "root" ]]; then
                                continue
                            fi
                        fi
                    else
                        if [[ "$existing_parent" != "$parent_match" ]]; then
                            continue
                        fi
                    fi

                    local existing_slug_lower
                    existing_slug_lower=$(printf '%s' "${folder_slug_by_id[$existing_id]:-}" | tr '[:upper:]' '[:lower:]')
                    if [[ -z "$existing_slug_lower" ]]; then
                        existing_slug_lower=$(printf '%s' "$(sanitize_slug "${folder_name_by_id[$existing_id]:-}")" | tr '[:upper:]' '[:lower:]')
                    fi
                    if [[ -n "$existing_slug_lower" && "$existing_slug_lower" == "$folder_slug_lower" ]]; then
                        candidate_match="$existing_id"
                        break
                    fi

                    local existing_name_lower
                    existing_name_lower=$(printf '%s' "${folder_name_by_id[$existing_id]:-}" | tr '[:upper:]' '[:lower:]')
                    if [[ -n "$folder_name_lower" && -n "$existing_name_lower" && "$existing_name_lower" == "$folder_name_lower" ]]; then
                        candidate_match="$existing_id"
                        break
                    fi
                done

                if [[ -n "$candidate_match" ]]; then
                    existing_folder_id="$candidate_match"
                    if [[ -n "$candidate_path" ]]; then
                        folder_path_lookup["$target_project_id|$candidate_path"]="$existing_folder_id"
                    fi
                    if [[ "$verbose" == "true" ]]; then
                        log DEBUG "Matched cached folder ID $existing_folder_id for path '$candidate_path' (project ${target_project_id})."
                    fi
                fi
            fi

            if [[ "$verbose" == "true" ]]; then
                local debug_path_display="$candidate_path"
                if [[ -z "$debug_path_display" ]]; then
                    debug_path_display="<unresolved>"
                fi
                log DEBUG "Evaluating folder '${folder_name:-<unnamed>}' targeting parent '${parent_key}' in project '${target_project_id}' (path: ${debug_path_display})"
            fi

            if [[ -z "$existing_folder_id" ]]; then
                local create_name="$folder_name"
                if [[ -z "$create_name" ]]; then
                    create_name=$(unslug_to_title "$folder_slug")
                fi
                if [[ "$verbose" == "true" ]]; then
                    log DEBUG "Creating folder '$create_name' under project '${target_project_id}' parent '${parent_folder_id:-root}'"
                fi
                local create_tmp
                create_tmp=$(mktemp -t n8n-folder-create-XXXXXXXX.json)
                if [[ -z "$create_tmp" ]]; then
                    log ERROR "Failed to allocate temporary file for folder creation request."
                    folder_failure=true
                    break
                fi

                local create_response
                if ! n8n_api_create_folder "$create_name" "$target_project_id" "$parent_folder_id" >"$create_tmp"; then
                    local api_status
                    api_status=$(printf '%s' "${N8N_API_LAST_STATUS:-}" | tr -d '[:space:]')
                    local api_body_lower
                    api_body_lower=$(printf '%s' "${N8N_API_LAST_BODY:-}" | tr '[:upper:]' '[:lower:]')
                    if [[ "$verbose" == "true" ]]; then
                        log DEBUG "Folder create failure status='${api_status:-<unset>}' body_preview='${api_body_lower:-<empty>}'"
                    fi
                    if [[ "$api_status" == 403* ]] && [[ "$api_body_lower" == *"plan lacks license"* ]]; then
                        folder_license_block=true
                        if [[ "$license_notice_emitted" != "true" ]]; then
                            log INFO "Skipping n8n folder creation because the current plan lacks Projects & Folders access. Folder operations will be skipped for the remaining workflows."
                            license_notice_emitted=true
                        else
                            log DEBUG "n8n plan lacks Projects & Folders access; folder creation for '$create_name' skipped."
                        fi
                        rm -f "$create_tmp"
                        break
                    fi
                    rm -f "$create_tmp"
                    log ERROR "Failed to create folder '$create_name' in project '${project_id_map[$target_project_id]:-Default}'"
                    folder_failure=true
                    break
                fi
                create_response=$(cat "$create_tmp" 2>/dev/null)
                rm -f "$create_tmp"
                local create_data
                create_data=$(printf '%s' "$create_response" | jq '.data // .' 2>/dev/null)
                if [[ "$verbose" == "true" ]]; then
                    local create_preview
                    create_preview=$(printf '%s' "$create_data" | tr '\n' ' ' | head -c 200)
                    local create_len
                    create_len=$(printf '%s' "$create_data" | wc -c | tr -d '[:space:]')
                    local create_suffix=""
                    if [[ ${create_len:-0} -gt 200 ]]; then
                        create_suffix="…"
                    fi
                    log DEBUG "Create folder response: ${create_preview}${create_suffix}"
                fi
                existing_folder_id=$(printf '%s' "$create_data" | jq -r '.id // empty' 2>/dev/null)
                if [[ -z "$existing_folder_id" ]]; then
                    log ERROR "n8n API did not return an ID when creating folder '$create_name'"
                    folder_failure=true
                    overall_success=false
                    break
                fi
                local response_name
                response_name=$(printf '%s' "$create_data" | jq -r '.name // empty' 2>/dev/null)
                if [[ -n "$response_name" && "$response_name" != "null" ]]; then
                    folder_name="$response_name"
                fi
                local response_slug
                response_slug=$(printf '%s' "$create_data" | jq -r '.slug // empty' 2>/dev/null)
                if [[ -n "$response_slug" && "$response_slug" != "null" ]]; then
                    folder_slug="$response_slug"
                fi
                local response_parent
                response_parent=$(normalize_entry_identifier "$(printf '%s' "$create_data" | jq -r '.parentFolderId // empty' 2>/dev/null)")
                parent_key="${response_parent:-root}"
                folder_name_lower=$(printf '%s' "$folder_name" | tr '[:upper:]' '[:lower:]')
                folder_slug_lower=$(printf '%s' "$folder_slug" | tr '[:upper:]' '[:lower:]')
                folder_parent_lookup["$existing_folder_id"]="$parent_key"
                folder_project_lookup["$existing_folder_id"]="$target_project_id"
                folder_slug_by_id["$existing_folder_id"]="$folder_slug"
                folder_name_by_id["$existing_folder_id"]="$folder_name"
                if [[ -n "$candidate_path" ]]; then
                    folder_path_lookup["$target_project_id|$candidate_path"]="$existing_folder_id"
                fi
                log INFO "Created n8n folder '$create_name' in project '${project_id_map[$target_project_id]:-Default}'"
                folder_created_count=$((folder_created_count + 1))
            fi

            if [[ -n "$existing_folder_id" ]]; then
                if [[ -n "$folder_slug_lower" ]]; then
                    local final_slug_key="$target_project_id|${parent_key}|$folder_slug_lower"
                    folder_slug_lookup["$final_slug_key"]="$existing_folder_id"
                fi
                if [[ -n "$folder_name_lower" ]]; then
                    local final_name_key="$target_project_id|${parent_key}|$folder_name_lower"
                    folder_name_lookup["$final_name_key"]="$existing_folder_id"
                fi
            fi

            parent_folder_id="$existing_folder_id"
            current_slug_path="$candidate_path"
        done

        if [[ "$folder_license_block" == "true" ]]; then
            license_feature_blocked=true
            break
        fi

        if $folder_failure; then
            overall_success=false
            continue
        fi

        if [[ -z "$workflow_id" ]]; then
            overall_success=false
            log WARN "Folder entry missing workflow ID; skipping."
            continue
        fi

        local assignment_folder_id
        assignment_folder_id=$(normalize_entry_identifier "${parent_folder_id:-}")
        local current_project
        current_project=$(normalize_entry_identifier "${workflow_project_lookup[$workflow_id]:-}")
        local current_parent
        current_parent=$(normalize_entry_identifier "${workflow_parent_lookup[$workflow_id]:-}")
        local version_id="${workflow_version_lookup[$workflow_id]:-}"
        local version_mode="string"
        local assignment_note=""

        if [[ -z "$version_id" || "$version_id" == "null" ]]; then
            local workflow_detail=""
            if workflow_detail=$(n8n_api_get_workflow "$workflow_id"); then
                local detail_payload
                detail_payload=$(printf '%s' "$workflow_detail" | jq -c '.data // .' 2>/dev/null)
                if [[ -n "$detail_payload" && "$detail_payload" != "null" ]]; then
                    local detail_version detail_parent detail_project
                    detail_version=$(printf '%s' "$detail_payload" | jq -r '.versionId // (.version.id // .versionId // empty)' 2>/dev/null)
                    detail_parent=$(normalize_entry_identifier "$(printf '%s' "$detail_payload" | jq -r '.parentFolderId // (.parentFolder.id // empty)' 2>/dev/null)")
                    detail_project=$(normalize_entry_identifier "$(printf '%s' "$detail_payload" | jq -r '.homeProject.id // .homeProjectId // empty' 2>/dev/null)")
                    if [[ -n "$detail_version" && "$detail_version" != "null" ]]; then
                        version_id="$detail_version"
                        workflow_version_lookup["$workflow_id"]="$detail_version"
                        version_mode="string"
                        if [[ "$verbose" == "true" ]]; then
                            log DEBUG "Refreshed workflow $workflow_id version metadata ($detail_version)."
                        fi
                    fi
                    if [[ -n "$detail_project" ]]; then
                        workflow_project_lookup["$workflow_id"]="$detail_project"
                        current_project="$detail_project"
                    fi
                    if [[ -n "$detail_parent" || "$detail_parent" == "" ]]; then
                        workflow_parent_lookup["$workflow_id"]="$detail_parent"
                        current_parent="$detail_parent"
                    fi
                fi
            else
                if [[ "$verbose" == "true" ]]; then
                    log DEBUG "Failed to refresh workflow $workflow_id metadata (HTTP ${N8N_API_LAST_STATUS:-unknown})."
                fi
            fi
        fi

        if [[ -z "$version_id" || "$version_id" == "null" ]]; then
            version_id=""
            version_mode="null"
            assignment_note="versionId-null"
        fi

        local normalized_assignment="${assignment_folder_id:-}"
        local normalized_current="${current_parent:-}"

        if [[ "$current_project" == "$target_project_id" && "$normalized_current" == "$normalized_assignment" ]]; then
            log DEBUG "Workflow '$workflow_name' ($workflow_id) already in desired project/folder; skipping update."
            append_assignment_audit_record "$assignment_tracking_file" "$workflow_id" "$workflow_name" "$target_project_id" "$assignment_folder_id" "$display_path" "$version_id" "$version_mode" "unchanged" "$assignment_note"
            assignment_tracking_count=$((assignment_tracking_count + 1))
            continue
        fi

        if [[ "$version_mode" == "null" && "$verbose" == "true" ]]; then
            log DEBUG "Attempting workflow '$workflow_name' ($workflow_id) reassignment with null versionId payload."
        fi

        if ! n8n_api_update_workflow_assignment "$workflow_id" "$target_project_id" "$assignment_folder_id" "$version_id" "$version_mode"; then
            local assign_status
            assign_status=$(printf '%s' "${N8N_API_LAST_STATUS:-}" | tr -d '[:space:]')
            local assign_body_lower
            assign_body_lower=$(printf '%s' "${N8N_API_LAST_BODY:-}" | tr '[:upper:]' '[:lower:]')
            if [[ "$assign_status" == 403* ]] && [[ "$assign_body_lower" == *"plan lacks license"* ]]; then
                license_feature_blocked=true
                if [[ "$license_notice_emitted" != "true" ]]; then
                    log INFO "Skipping workflow folder reassignments because the current n8n plan lacks Projects & Folders access."
                    license_notice_emitted=true
                else
                    log DEBUG "n8n plan lacks Projects & Folders access; workflow '$workflow_name' ($workflow_id) remains in its existing folder."
                fi
                local license_note="$assignment_note"
                if [[ -n "$license_note" ]]; then
                    license_note="$license_note;license-blocked"
                else
                    license_note="license-blocked"
                fi
                append_assignment_audit_record "$assignment_tracking_file" "$workflow_id" "$workflow_name" "$target_project_id" "$assignment_folder_id" "$display_path" "$version_id" "$version_mode" "license-blocked" "$license_note"
                assignment_tracking_count=$((assignment_tracking_count + 1))
                continue
            fi
            log WARN "Failed to assign workflow '$workflow_name' ($workflow_id) to target folder structure."
            overall_success=false
            local failure_note="$assignment_note"
            if [[ -n "$failure_note" ]]; then
                failure_note="$failure_note;api-update-failed"
            else
                failure_note="api-update-failed"
            fi
            append_assignment_audit_record "$assignment_tracking_file" "$workflow_id" "$workflow_name" "$target_project_id" "$assignment_folder_id" "$display_path" "$version_id" "$version_mode" "error" "$failure_note"
            assignment_tracking_count=$((assignment_tracking_count + 1))
            continue
        fi

        workflow_project_lookup["$workflow_id"]="$target_project_id"
        workflow_parent_lookup["$workflow_id"]="$assignment_folder_id"
        moved_count=$((moved_count + 1))
        workflow_assignment_count=$((workflow_assignment_count + 1))
        local success_note="$assignment_note"
        append_assignment_audit_record "$assignment_tracking_file" "$workflow_id" "$workflow_name" "$target_project_id" "$assignment_folder_id" "$display_path" "$version_id" "$version_mode" "moved" "$success_note"
        assignment_tracking_count=$((assignment_tracking_count + 1))
        local version_label="$version_id"
        if [[ "$version_mode" == "null" ]]; then
            version_label="<null>"
        elif [[ -z "$version_label" ]]; then
            version_label="<unset>"
        fi
        log INFO "Workflow '$workflow_name' ($workflow_id) reassigned to project '$target_project_id' folder '${assignment_folder_id:-root}' (version ${version_label})."
    done < "$entry_records_file"
    rm -f "$entry_records_file"

    if [[ ${assignment_tracking_count:-0} -gt 0 ]]; then
        local assignment_summary_file
        assignment_summary_file=$(mktemp -t n8n-workflow-assignment-summary-XXXXXXXX.json)
        if jq -s '.' "$assignment_tracking_file" > "$assignment_summary_file" 2>/dev/null; then
            log INFO "Recorded workflow assignment audit to $assignment_summary_file"
        else
            log WARN "Unable to collate workflow assignment audit log from $assignment_tracking_file"
            rm -f "$assignment_summary_file"
        fi
    fi
    rm -f "$assignment_tracking_file"

    finalize_n8n_api_auth

    # Export folder structure metrics for use in restore summary
    export RESTORE_PROJECTS_CREATED="$project_created_count"
    export RESTORE_FOLDERS_CREATED="$folder_created_count"
    export RESTORE_FOLDERS_MOVED="$folder_moved_count"
    export RESTORE_WORKFLOWS_REASSIGNED="$workflow_assignment_count"
    export RESTORE_FOLDER_SYNC_RAN="true"

    # Report folder structure operations (DEBUG level - full summary will be in restore closeout)
    if [[ $project_created_count -gt 0 || $folder_created_count -gt 0 || $folder_moved_count -gt 0 || $workflow_assignment_count -gt 0 ]]; then
        log DEBUG "Folder structure synchronized: ${project_created_count} project(s) created, ${folder_created_count} folder(s) created, ${folder_moved_count} folder(s) repositioned, ${workflow_assignment_count} workflow(s) reassigned."
    else
        log DEBUG "Folder structure verified: All workflows already in target folders."
    fi

    if [[ "$license_feature_blocked" == "true" ]]; then
        log DEBUG "Folder structure restoration skipped because the current n8n plan lacks Projects & Folders access."
        return 0
    fi

    if ! $overall_success; then
        log DEBUG "Folder structure restoration completed with warnings (${moved_count}/${total_count} workflows updated)."
        return 1
    fi

    log DEBUG "Folder structure restored for $moved_count workflow(s)."
    return 0
}

stage_directory_workflows_to_container() {
    local source_dir="$1"
    local container_id="$2"
    local container_target_dir="$3"
    local manifest_output="${4:-}"
    local existing_snapshot="${5:-}"
    local preserve_ids="${6:-false}"
    local no_overwrite="${7:-false}"
    local existing_mapping="${8:-}"

    if [[ "$preserve_ids" != "true" ]]; then
        preserve_ids=false
    fi

    no_overwrite=$(printf '%s' "$no_overwrite" | tr '[:upper:]' '[:lower:]')
    if [[ "$no_overwrite" == "true" ]]; then
        no_overwrite=true
        preserve_ids=false
        if [[ "$verbose" == "true" ]]; then
            log DEBUG "no-overwrite enabled: workflow IDs will be cleared prior to import."
        fi
    else
        no_overwrite=false
    fi

    if [[ -z "$source_dir" || ! -d "$source_dir" ]]; then
        log ERROR "Workflow directory not found: ${source_dir:-<empty>}"
        return 1
    fi

    local staging_dir
    local staging_dir
    staging_dir=$(mktemp -d -t n8n-structured-import-XXXXXXXXXX)
    local copy_success=true
    local staged_count=0
    local jq_sanitize_script
    jq_sanitize_script=$(cat <<'JQ'
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

.active = (if (.active | type) == "boolean" then .active else false end)
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
JQ
)
    local manifest_entries_file=""
    if [[ -n "$manifest_output" ]]; then
        manifest_entries_file=$(mktemp -t n8n-staged-manifest-XXXXXXXX.ndjson)
    fi

    declare -A staged_workflow_ids=()

    while IFS= read -r -d '' workflow_file; do
        local filename
        filename=$(basename "$workflow_file")

        if [[ -z "$filename" || "$filename" == ".json" ]]; then
            filename="workflow_${staged_count}.json"
        fi

        local relative_path="${workflow_file#$source_dir/}"
        if [[ "$relative_path" == "$workflow_file" ]]; then
            relative_path="$filename"
        fi

        local relative_dir="${relative_path%/*}"
        if [[ "$relative_dir" == "$relative_path" ]]; then
            relative_dir=""
        fi
        relative_dir="${relative_dir#/}"
        relative_dir="${relative_dir%/}"

        local relative_dir_without_prefix
        relative_dir_without_prefix="$(strip_github_path_prefix "$relative_dir")"
        relative_dir_without_prefix="${relative_dir_without_prefix#/}"
        relative_dir_without_prefix="${relative_dir_without_prefix%/}"

        local canonical_relative_path
        canonical_relative_path="$(strip_github_path_prefix "$relative_path")"
        canonical_relative_path="${canonical_relative_path#/}"
        canonical_relative_path="${canonical_relative_path%/}"

        local repo_entry_path
        repo_entry_path="$(compose_repo_storage_path "$canonical_relative_path")"
        repo_entry_path="${repo_entry_path#/}"
        repo_entry_path="${repo_entry_path%/}"

        local canonical_storage_path
        canonical_storage_path="$(compose_repo_storage_path "$relative_dir_without_prefix")"
        canonical_storage_path="${canonical_storage_path#/}"
        canonical_storage_path="${canonical_storage_path%/}"

    local expected_project_slug=""
    local expected_project_slug_norm=""
        local expected_project_display=""
        local -a expected_folder_slugs=()
        local -a expected_folder_displays=()
        local expected_display_path=""

        compute_entry_folder_context \
            "$relative_dir_without_prefix" \
            expected_project_slug \
            expected_project_display \
            expected_folder_slugs \
            expected_folder_displays \
            expected_display_path

        if [[ -n "$expected_project_slug" ]]; then
            expected_project_slug_norm=$(normalize_manifest_lookup_key "$expected_project_slug")
        fi

        local expected_folder_slug_path=""
        if ((${#expected_folder_slugs[@]} > 0)); then
            expected_folder_slug_path=$(IFS=/; printf '%s' "${expected_folder_slugs[*]}")
        fi

        local expected_folder_display_path=""
        if ((${#expected_folder_displays[@]} > 0)); then
            expected_folder_display_path=$(IFS=/; printf '%s' "${expected_folder_displays[*]}")
        fi

        local expected_project_and_slug_path=""
        if [[ -n "$expected_project_slug" ]]; then
            expected_project_and_slug_path="$expected_project_slug"
            if [[ -n "$expected_folder_slug_path" ]]; then
                expected_project_and_slug_path+="/$expected_folder_slug_path"
            fi
        elif [[ -n "$expected_folder_slug_path" ]]; then
            expected_project_and_slug_path="$expected_folder_slug_path"
        fi

        local expected_relative_path="$expected_project_and_slug_path"
        if [[ -z "$expected_relative_path" && -n "$expected_project_slug" ]]; then
            expected_relative_path="$expected_project_slug"
        fi

        if [[ -n "$repo_entry_path" ]] && ! path_matches_github_prefix "$repo_entry_path"; then
            log DEBUG "Skipping workflow outside configured GITHUB_PATH: $workflow_file"
            continue
        fi

        local dest_filename="$filename"
        local base_name="${filename%.json}"
        local suffix=1
        while [[ -e "$staging_dir/$dest_filename" ]]; do
            dest_filename="${base_name}_${suffix}.json"
            suffix=$((suffix + 1))
        done

        local staged_path="$staging_dir/$dest_filename"
        if ! jq "$jq_sanitize_script" "$workflow_file" > "$staged_path"; then
            rm -f "$staged_path"
            log WARN "Failed to normalize workflow file: $workflow_file"
            if ! cp "$workflow_file" "$staging_dir/$dest_filename"; then
                log WARN "Failed to stage workflow file: $workflow_file"
                copy_success=false
                continue
            fi
        fi

        # Extract workflow metadata BEFORE modifying the file
    local staged_id staged_name staged_instance staged_description staged_id_valid="false" id_sanitized_note=""
    staged_id=$(jq -r '.id // empty' "$staged_path" 2>/dev/null || printf '')
        staged_name=$(jq -r '.name // empty' "$staged_path" 2>/dev/null || printf '')
        staged_instance=$(jq -r '.meta.instanceId // empty' "$staged_path" 2>/dev/null || printf '')
        staged_description=$(jq -r '.description // empty' "$staged_path" 2>/dev/null || printf '')
        local original_staged_id="$staged_id"
        local resolved_id_source=""
        local mapping_match_json=""
    local duplicate_match_json=""
    local existing_storage_path=""
    local existing_display_path=""
    local existing_workflow_id=""
    local name_match_json=""
    local name_match_id=""
    local name_match_relpath=""
    local name_match_type=""
    local name_match_allowed="false"
    local id_conflict_resolved_via_name="false"
    local name_match_candidate_path=""
        local folder_match_applied="false"
        local folder_name_match_entry=""
        local folder_name_match_count=0

        if [[ -n "$staged_id" ]]; then
            if [[ "$staged_id" =~ ^[A-Za-z0-9]{16}$ ]]; then
                staged_id_valid="true"
            else
                if jq 'del(.id)' "$staged_path" > "${staged_path}.tmp" 2>/dev/null; then
                    mv "${staged_path}.tmp" "$staged_path"
                    staged_id=""
                    id_sanitized_note="sanitized-invalid-format"
                    if [[ "$verbose" == "true" ]]; then
                        log DEBUG "Removed invalid workflow ID '$original_staged_id' (expected 16-char alphanumeric)."
                    fi
                else
                    rm -f "${staged_path}.tmp"
                    log WARN "Unable to sanitize invalid workflow ID '$staged_id' for '${staged_name:-$dest_filename}'."
                fi
            fi
        fi

        if [[ "$folder_match_applied" != "true" ]]; then
            if [[ -n "$existing_mapping" && -f "$existing_mapping" && -n "$staged_name" ]]; then
                mapping_match_json=$(lookup_workflow_in_mapping "$existing_mapping" "$canonical_storage_path" "$staged_name") || mapping_match_json=""
                if [[ "$mapping_match_json" == "null" ]]; then
                    mapping_match_json=""
                fi
            fi

            if [[ -n "$mapping_match_json" ]]; then
                duplicate_match_json="$mapping_match_json"
                resolved_id_source=$(printf '%s' "$mapping_match_json" | jq -r '.matchType // empty' 2>/dev/null)
            fi

            if [[ -z "$duplicate_match_json" ]]; then
                if [[ -n "$existing_snapshot" && -f "$existing_snapshot" ]]; then
                    duplicate_match_json=$(match_existing_workflow "$existing_snapshot" "$staged_id" "$staged_instance" "$staged_name" "$staged_description" "$repo_entry_path" "$existing_mapping") || duplicate_match_json=""
                elif [[ -n "$existing_mapping" && -f "$existing_mapping" ]]; then
                    duplicate_match_json=$(match_existing_workflow "" "$staged_id" "$staged_instance" "$staged_name" "$staged_description" "$repo_entry_path" "$existing_mapping") || duplicate_match_json=""
                fi
            fi
        fi

        local duplicate_match_type=""
        if [[ -n "$duplicate_match_json" ]]; then
            duplicate_match_type=$(printf '%s' "$duplicate_match_json" | jq -r '.matchType // empty' 2>/dev/null)
            local duplicate_existing_id
            duplicate_existing_id=$(printf '%s' "$duplicate_match_json" | jq -r '.workflow.id // empty' 2>/dev/null)
            if [[ "$folder_match_applied" != "true" || -z "$existing_workflow_id" ]]; then
                existing_workflow_id="$duplicate_existing_id"
            fi
            if [[ -z "$existing_storage_path" ]]; then
                existing_storage_path=$(printf '%s' "$duplicate_match_json" | jq -r '.storagePath // .workflow.relativePath // empty' 2>/dev/null)
            fi
            if [[ -z "$existing_display_path" ]]; then
                existing_display_path=$(printf '%s' "$duplicate_match_json" | jq -r '.displayPath // .workflow.displayPath // empty' 2>/dev/null)
            fi
            if [[ -z "$resolved_id_source" && -n "$duplicate_match_type" ]]; then
                resolved_id_source="$duplicate_match_type"
            fi
            # Verbose duplicate detection logging removed - final ID will be logged after all resolution steps
        fi

        if [[ "$folder_match_applied" != "true" && -n "$staged_name" ]]; then
            name_match_json=$(match_existing_workflow "$existing_snapshot" "" "$staged_instance" "$staged_name" "$staged_description" "$repo_entry_path" "$existing_mapping") || name_match_json=""
            if [[ "$name_match_json" == "null" ]]; then
                name_match_json=""
            fi
            if [[ -n "$name_match_json" ]]; then
                name_match_type=$(printf '%s' "$name_match_json" | jq -r '.matchType // empty' 2>/dev/null)
                name_match_id=$(printf '%s' "$name_match_json" | jq -r '.workflow.id // empty' 2>/dev/null)
                name_match_relpath=$(printf '%s' "$name_match_json" | jq -r '.workflow.relativePath // empty' 2>/dev/null)

                local mapping_candidate=""
                local mapping_candidate_found="false"
                if [[ -n "$existing_mapping" && -f "$existing_mapping" && -n "$name_match_id" ]]; then
                    if mapping_candidate=$(lookup_workflow_path_by_id "$existing_mapping" "$name_match_id"); then
                        mapping_candidate_found="true"
                        name_match_candidate_path="$mapping_candidate"
                    fi
                fi

                if [[ "$mapping_candidate_found" != "true" ]]; then
                    if [[ -n "$name_match_relpath" ]]; then
                        name_match_candidate_path="$name_match_relpath"
                    else
                        name_match_candidate_path=""
                    fi
                else
                    if [[ -z "$name_match_relpath" ]]; then
                        name_match_relpath="$name_match_candidate_path"
                    fi
                fi

                local candidate_folder_display=""
                candidate_folder_display=$(printf '%s' "$name_match_json" | jq -r '.workflow.folders | (map(.name) | join("/")) // empty' 2>/dev/null)

                local candidate_folder_path_raw=""
                if [[ -n "$name_match_candidate_path" ]]; then
                    candidate_folder_path_raw="$name_match_candidate_path"
                fi

                local candidate_folder_path=""
                if [[ -n "$candidate_folder_path_raw" ]]; then
                    local candidate_extension
                    candidate_extension=$(printf '%s' "${candidate_folder_path_raw##*.}" | tr '[:upper:]' '[:lower:]')
                    if [[ "$candidate_extension" == "json" ]]; then
                        candidate_folder_path="${candidate_folder_path_raw%/*}"
                        if [[ "$candidate_folder_path" == "$candidate_folder_path_raw" ]]; then
                            candidate_folder_path=""
                        fi
                    else
                        candidate_folder_path="$candidate_folder_path_raw"
                    fi
                fi

                candidate_folder_path="${candidate_folder_path#/}"
                candidate_folder_path="${candidate_folder_path%/}"

                if [[ -z "$candidate_folder_display" && -n "$candidate_folder_path" ]]; then
                    candidate_folder_display="$candidate_folder_path"
                fi

                local expected_folder_display="$expected_folder_display_path"
                if [[ -z "$expected_folder_display" ]]; then
                    expected_folder_display="$expected_display_path"
                fi
                local expected_folder_path="$canonical_storage_path"

                local candidate_storage_norm=""
                local expected_storage_norm=""
                if [[ -n "$candidate_folder_path" ]]; then
                    candidate_storage_norm=$(normalize_manifest_lookup_key "$candidate_folder_path")
                fi
                if [[ -n "$expected_folder_path" ]]; then
                    expected_storage_norm=$(normalize_manifest_lookup_key "$expected_folder_path")
                fi

                local candidate_path_norm=""
                if [[ -n "$name_match_candidate_path" ]]; then
                    candidate_path_norm=$(normalize_manifest_lookup_key "$name_match_candidate_path")
                fi
                local expected_path_norm=""
                if [[ -n "$repo_entry_path" ]]; then
                    expected_path_norm=$(normalize_manifest_lookup_key "$repo_entry_path")
                fi

                local candidate_display_norm
                candidate_display_norm=$(normalize_manifest_lookup_key "$candidate_folder_display")
                local expected_display_norm
                expected_display_norm=$(normalize_manifest_lookup_key "$expected_folder_display")

                local candidate_matches_expected="false"
                if [[ -n "$candidate_path_norm" && -n "$expected_path_norm" ]]; then
                    if manifest_lookup_path_matches "$candidate_path_norm" "$expected_path_norm" "$expected_project_slug_norm"; then
                        candidate_matches_expected="true"
                    fi
                fi

                if [[ "$candidate_matches_expected" != "true" && -n "$candidate_storage_norm" && -n "$expected_storage_norm" ]]; then
                    if manifest_lookup_path_matches "$candidate_storage_norm" "$expected_storage_norm" "$expected_project_slug_norm"; then
                        candidate_matches_expected="true"
                    fi
                fi

                if [[ "$candidate_matches_expected" != "true" && -n "$candidate_display_norm" && -n "$expected_display_norm" ]]; then
                    if manifest_lookup_path_matches "$candidate_display_norm" "$expected_display_norm" "$expected_project_slug_norm"; then
                        candidate_matches_expected="true"
                    fi
                fi

                if [[ "$candidate_matches_expected" != "true" && -z "$candidate_storage_norm" && -z "$expected_storage_norm" && -z "$candidate_display_norm" && -z "$expected_display_norm" ]]; then
                    candidate_matches_expected="true"
                fi

                if [[ "$candidate_matches_expected" == "true" ]]; then
                    name_match_allowed="true"
                elif [[ -n "$name_match_id" && -z "$name_match_candidate_path" ]]; then
                    name_match_allowed="true"
                    if [[ "$verbose" == "true" ]]; then
                        log DEBUG "Allowing name-based duplicate alignment for '${staged_name:-$dest_filename}' (ID ${name_match_id}) despite missing folder metadata."
                    fi
                elif [[ "$verbose" == "true" ]]; then
                    log DEBUG "Skipping name-based duplicate alignment for '${staged_name:-$dest_filename}' due to folder mismatch (candidate='${candidate_folder_display:-<empty>}', expected='${expected_folder_display:-<empty>}')."
                fi

                if [[ "$name_match_allowed" == "true" ]]; then
                    if [[ -z "$existing_storage_path" && -n "$name_match_candidate_path" ]]; then
                        existing_storage_path="$name_match_candidate_path"
                    fi
                    if [[ -z "$existing_display_path" && -n "$expected_display_path" ]]; then
                        existing_display_path="$expected_display_path"
                    fi
                    if [[ -z "$duplicate_match_json" ]]; then
                        duplicate_match_json="$name_match_json"
                        duplicate_match_type="$name_match_type"
                        if [[ -z "$existing_workflow_id" ]]; then
                            existing_workflow_id="$name_match_id"
                        fi
                        if [[ -z "$resolved_id_source" && -n "$name_match_type" ]]; then
                            resolved_id_source="$name_match_type"
                        fi
                    fi
                fi
            fi
        fi

        if [[ "$preserve_ids" != "true" && "$no_overwrite" != "true" && "$name_match_allowed" == "true" && -n "$name_match_id" ]]; then
            if [[ "$staged_id" != "$name_match_id" || -z "$staged_id" ]]; then
                if [[ "$name_match_id" =~ ^[A-Za-z0-9]{16}$ ]]; then
                    if jq --arg id "$name_match_id" '.id = $id' "$staged_path" > "${staged_path}.tmp" 2>/dev/null; then
                        mv "${staged_path}.tmp" "$staged_path"
                        staged_id="$name_match_id"
                        staged_id_valid="true"
                        existing_workflow_id="$name_match_id"
                        resolved_id_source="name-match"
                        id_conflict_resolved_via_name="true"
                        # ID alignment logging moved to final preparation step for clarity
                    else
                        rm -f "${staged_path}.tmp"
                        log WARN "Failed to apply name-matched workflow ID '$name_match_id' for '${staged_name:-$dest_filename}'."
                    fi
                elif [[ "$verbose" == "true" ]]; then
                    log DEBUG "Name-matched workflow ID '$name_match_id' for '${staged_name:-$dest_filename}' is invalid; leaving staged ID unchanged."
                fi
            fi
        fi

        local id_exists_in_target="false"
        if [[ -n "$staged_id" ]]; then
            if [[ -n "$existing_workflow_id" && "$existing_workflow_id" == "$staged_id" ]]; then
                id_exists_in_target="true"
            elif [[ "$duplicate_match_type" == "id" ]]; then
                id_exists_in_target="true"
            elif [[ -n "$existing_snapshot" && -f "$existing_snapshot" ]]; then
                if jq -e --arg id "$staged_id" '
                        (if type == "array" then . else [])
                        | map(select(((.id // empty) | tostring) == $id))
                        | length > 0
                    ' "$existing_snapshot" >/dev/null 2>&1; then
                    id_exists_in_target="true"
                fi
            fi
        fi

        if [[ "$preserve_ids" == "true" && -n "$existing_workflow_id" ]]; then
            if [[ "$staged_id" != "$existing_workflow_id" ]]; then
                if jq --arg id "$existing_workflow_id" '.id = $id' "$staged_path" > "${staged_path}.tmp"; then
                    mv "${staged_path}.tmp" "$staged_path"
                    staged_id="$existing_workflow_id"
                    staged_id_valid=$([[ "$staged_id" =~ ^[A-Za-z0-9]{16}$ ]] && printf 'true' || printf 'false')
                    if [[ "$staged_id_valid" != "true" ]]; then
                        if jq 'del(.id)' "$staged_path" > "${staged_path}.tmp" 2>/dev/null; then
                            mv "${staged_path}.tmp" "$staged_path"
                            id_sanitized_note="sanitized-existing-invalid"
                            staged_id=""
                            if [[ "$verbose" == "true" ]]; then
                                log DEBUG "Existing workflow ID '$existing_workflow_id' failed validation and was removed prior to import."
                            fi
                        else
                            rm -f "${staged_path}.tmp"
                            log WARN "Unable to sanitize invalid existing workflow ID '$existing_workflow_id' for '${staged_name:-$dest_filename}'."
                        fi
                    fi
                    # ID alignment logging consolidated into final import preparation step
                else
                    rm -f "${staged_path}.tmp"
                    log WARN "Failed to apply resolved workflow ID '${existing_workflow_id}' for '${staged_name:-$dest_filename}'."
                fi
            fi
        fi

        if [[ "$preserve_ids" != "true" && -n "$staged_id" ]]; then
            local clear_reason=""
            if [[ -n "$name_match_id" && "$name_match_allowed" != "true" ]]; then
                clear_reason="folder-name-mismatch"
            elif [[ "$no_overwrite" == "true" ]]; then
                clear_reason="no-overwrite"
            elif [[ "$id_exists_in_target" == "true" ]]; then
                if [[ "$id_conflict_resolved_via_name" == "true" ]]; then
                    clear_reason=""
                else
                    clear_reason="id-conflict"
                fi
            fi

            if [[ -n "$clear_reason" ]]; then
                if jq 'del(.id)' "$staged_path" > "${staged_path}.tmp" 2>/dev/null; then
                    mv "${staged_path}.tmp" "$staged_path"
                    if [[ "$verbose" == "true" ]]; then
                        if [[ "$clear_reason" == "no-overwrite" ]]; then
                            log DEBUG "Cleared workflow ID '${staged_id}' for '${staged_name:-$dest_filename}' because --no-overwrite is enabled."
                        elif [[ "$clear_reason" == "folder-name-mismatch" ]]; then
                            log DEBUG "Cleared workflow ID '${staged_id}' for '${staged_name:-$dest_filename}' because no matching workflow exists in the target folder."
                        else
                            log DEBUG "Cleared workflow ID '${staged_id}' for '${staged_name:-$dest_filename}' due to existing ID conflict in target instance."
                        fi
                    fi
                    staged_id=""
                    if [[ "$clear_reason" == "no-overwrite" ]]; then
                        id_sanitized_note=$(append_sanitized_note "$id_sanitized_note" "no-overwrite")
                    elif [[ "$clear_reason" == "folder-name-mismatch" ]]; then
                        id_sanitized_note=$(append_sanitized_note "$id_sanitized_note" "folder-name-mismatch")
                    else
                        id_sanitized_note=$(append_sanitized_note "$id_sanitized_note" "id-conflict")
                    fi
                else
                    rm -f "${staged_path}.tmp"
                    log WARN "Unable to clear workflow ID '${staged_id}' for '${staged_name:-$dest_filename}' (${clear_reason})."
                fi
            else
                local staged_folder_norm
                staged_folder_norm=$(normalize_manifest_lookup_key "$canonical_storage_path")
                local prior_folder=""
                if [[ -n "${staged_workflow_ids[$staged_id]+x}" ]]; then
                    prior_folder="${staged_workflow_ids[$staged_id]}"
                fi

                local duplicate_within_stage="false"
                if [[ -n "$prior_folder" ]]; then
                    local prior_folder_norm
                    prior_folder_norm=$(normalize_manifest_lookup_key "$prior_folder")
                    if [[ -z "$prior_folder_norm" && -z "$staged_folder_norm" ]]; then
                        duplicate_within_stage="true"
                    elif [[ -n "$prior_folder_norm" && "$prior_folder_norm" == "$staged_folder_norm" ]]; then
                        duplicate_within_stage="true"
                    fi
                fi

                if [[ -n "$prior_folder" && "$duplicate_within_stage" != "true" ]]; then
                    if jq 'del(.id)' "$staged_path" > "${staged_path}.tmp" 2>/dev/null; then
                        mv "${staged_path}.tmp" "$staged_path"
                        if [[ "$verbose" == "true" ]]; then
                            log DEBUG "Cleared workflow ID '${staged_id}' for '${staged_name:-$dest_filename}' due to duplicate ID conflict with staged workflow in a different folder."
                        fi
                        id_sanitized_note=$(append_sanitized_note "$id_sanitized_note" "staged-duplicate-conflict")
                        staged_id=""
                    else
                        rm -f "${staged_path}.tmp"
                        log WARN "Unable to clear staged duplicate workflow ID '${staged_id}' for '${staged_name:-$dest_filename}'."
                    fi
                else
                    staged_workflow_ids[$staged_id]="$canonical_storage_path"
                    # ID retention logged in final import preparation step
                fi
            fi
        fi

        if [[ "$preserve_ids" == "true" && -z "$existing_workflow_id" && -n "$staged_id" ]]; then
            if [[ "$id_exists_in_target" != "true" ]]; then
                if [[ "$staged_id_valid" == "true" ]]; then
                    if [[ "$verbose" == "true" ]]; then
                        log DEBUG "Retained user-provided workflow ID '${staged_id}' for '${staged_name:-$dest_filename}' (no conflicts detected)."
                    fi
                else
                    if jq 'del(.id)' "$staged_path" > "${staged_path}.tmp"; then
                        mv "${staged_path}.tmp" "$staged_path"
                        if [[ "$verbose" == "true" ]]; then
                            log DEBUG "Cleared orphan workflow ID '${staged_id}' for '${staged_name:-$dest_filename}' (no matching workflow found)."
                        fi
                        if [[ -z "$id_sanitized_note" ]]; then
                            id_sanitized_note="sanitized-orphan-invalid"
                        fi
                        staged_id=""
                    else
                        rm -f "${staged_path}.tmp"
                        log WARN "Unable to clear orphan workflow ID '${staged_id}' for '${staged_name:-$dest_filename}'."
                    fi
                fi
            elif [[ "$staged_id_valid" != "true" ]]; then
                # ID was invalid but matched a known workflow; ensure file does not contain bad ID
                if jq 'del(.id)' "$staged_path" > "${staged_path}.tmp" 2>/dev/null; then
                    mv "${staged_path}.tmp" "$staged_path"
                    id_sanitized_note="sanitized-orphan-invalid"
                    staged_id=""
                    if [[ "$verbose" == "true" ]]; then
                        log DEBUG "Removed invalid workflow ID '${original_staged_id}' lacking known matches for '${staged_name:-$dest_filename}'."
                    fi
                else
                    rm -f "${staged_path}.tmp"
                    log WARN "Unable to remove invalid workflow ID '${original_staged_id}' for '${staged_name:-$dest_filename}'."
                fi
            fi
        fi

        # Log final ID resolution decision
        if [[ "$verbose" == "true" ]]; then
            if [[ -n "$staged_id" ]]; then
                local resolution_reason=""
                if [[ -n "$existing_workflow_id" && "$existing_workflow_id" == "$staged_id" ]]; then
                    resolution_reason=" (reusing existing workflow ID)"
                elif [[ "$id_conflict_resolved_via_name" == "true" ]]; then
                    resolution_reason=" (matched by name to existing workflow)"
                elif [[ -n "$original_staged_id" && "$original_staged_id" != "$staged_id" ]]; then
                    resolution_reason=" (sanitized from '$original_staged_id')"
                fi
                log DEBUG "Importing '${staged_name:-$dest_filename}' with ID '${staged_id}'${resolution_reason}"
            else
                log DEBUG "Importing '${staged_name:-$dest_filename}' with new n8n-assigned ID"
            fi
        fi

        # Build manifest entry - Store workflow ID for post-import folder assignment
        if [[ -n "$manifest_entries_file" ]]; then
            local manifest_entry match_type_field=""
            
            if [[ -n "$duplicate_match_json" ]]; then
                match_type_field=$(printf '%s' "$duplicate_match_json" | jq -r '.matchType // empty' 2>/dev/null)
                if [[ -z "$existing_storage_path" ]]; then
                    existing_storage_path=$(printf '%s' "$duplicate_match_json" | jq -r '.storagePath // empty' 2>/dev/null)
                fi
                if [[ -z "$existing_display_path" ]]; then
                    existing_display_path=$(printf '%s' "$duplicate_match_json" | jq -r '.displayPath // .workflow.displayPath // empty' 2>/dev/null)
                fi
            fi

            # Manifest entry contains:
            # - id: The workflow ID that will exist after import (from file or n8n-assigned)
            # - name: Backup identifier for name-based lookup if ID lookup fails
            # - storagePath: Determines folder structure
            # - existingWorkflowId: The ID that existed before (for tracking replacements)
            local manifest_entry
            manifest_entry=$(jq -nc \
                --arg filename "$dest_filename" \
                --arg id "$staged_id" \
                --arg name "$staged_name" \
                --arg description "$staged_description" \
                --arg instanceId "$staged_instance" \
                --arg matchType "$match_type_field" \
                --arg existingId "$existing_workflow_id" \
                --arg originalId "$original_staged_id" \
                --arg relative "$relative_path" \
                --arg storage "$canonical_storage_path" \
                --arg existingStorage "$existing_storage_path" \
                --arg existingDisplay "$existing_display_path" \
                --arg idSource "$resolved_id_source" \
                --arg sanitizeNote "$id_sanitized_note" \
                --arg preserveMode "$preserve_ids" \
                --arg noOverwrite "$no_overwrite" \
                --arg nameMatchId "$name_match_id" \
                --arg nameMatchPath "$name_match_relpath" \
                --arg nameMatchType "$name_match_type" \
                --arg alignedByName "$id_conflict_resolved_via_name" \
                --arg targetProjectSlug "$expected_project_slug" \
                --arg targetProjectName "$expected_project_display" \
                --arg targetDisplayPath "$expected_display_path" \
                --arg targetFolderSlugPath "$expected_folder_slug_path" \
                --arg targetFolderDisplayPath "$expected_folder_display_path" \
                                '{
                                    filename: $filename,
                                    id: $id,
                                    name: $name,
                                    description: $description,
                                    metaInstanceId: $instanceId,
                                    duplicateMatchType: $matchType,
                                    existingWorkflowId: $existingId,
                                    originalWorkflowId: $originalId,
                                    relativePath: $relative,
                                    storagePath: $storage,
                                    existingStoragePath: $existingStorage,
                                    existingDisplayPath: (if ($existingDisplay | length) > 0 then $existingDisplay else null end),
                                    idResolutionSource: $idSource,
                                    sanitizedIdNote: $sanitizeNote,
                                    preserveIds: ($preserveMode == "true"),
                                    noOverwrite: ($noOverwrite == "true"),
                                    nameMatchWorkflowId: (if ($nameMatchId | length) > 0 then $nameMatchId else null end),
                                    nameMatchRelativePath: (if ($nameMatchPath | length) > 0 then $nameMatchPath else null end),
                                    nameMatchType: (if ($nameMatchType | length) > 0 then $nameMatchType else null end),
                                    idAlignedByNameMatch: ($alignedByName == "true"),
                                    targetProjectSlug: (if ($targetProjectSlug | length) > 0 then $targetProjectSlug else null end),
                                    targetProjectName: (if ($targetProjectName | length) > 0 then $targetProjectName else null end),
                                    targetDisplayPath: (if ($targetDisplayPath | length) > 0 then $targetDisplayPath else null end),
                                    targetFolderSlugPath: (if ($targetFolderSlugPath | length) > 0 then $targetFolderSlugPath else null end),
                                    targetFolderDisplayPath: (if ($targetFolderDisplayPath | length) > 0 then $targetFolderDisplayPath else null end)
                                }
                                | with_entries(
                                        if (.value == null or (.value | tostring) == "") then empty else . end
                                    )') ||  {
                log ERROR "Failed to create manifest entry for '$dest_filename'"
                continue
            }
            printf '%s\n' "$manifest_entry" >> "$manifest_entries_file"
        fi

        staged_count=$((staged_count + 1))
    done < <(find "$source_dir" -type f -name "*.json" \
        ! -path "*/.credentials/*" \
        ! -path "*/archive/*" \
        ! -name "credentials.json" \
        ! -name ".n8n-folder-structure.json" -print0)

    if [[ "$staged_count" -eq 0 ]]; then
        if [[ -n "$manifest_entries_file" ]]; then
            if [[ -s "$manifest_entries_file" ]]; then
                if [[ -n "$manifest_output" ]]; then
                    # Keep NDJSON format - just copy
                    if ! cp "$manifest_entries_file" "$manifest_output" 2>/dev/null; then
                        log WARN "Unable to generate staging manifest for workflows; duplicate detection may be limited."
                        : > "$manifest_output" 2>/dev/null || true
                    fi
                fi
            elif [[ -n "$manifest_output" ]]; then
                : > "$manifest_output" 2>/dev/null || true
            fi
            rm -f "$manifest_entries_file"
        fi
        rm -rf "$staging_dir"
        log ERROR "No workflow JSON files found in directory: $source_dir"
        return 1
    fi

    if ! $copy_success; then
        rm -rf "$staging_dir"
        if [[ -n "$manifest_entries_file" ]]; then
            rm -f "$manifest_entries_file"
        fi
        return 1
    fi

    if [[ -z "$container_target_dir" ]]; then
        rm -rf "$staging_dir"
        log ERROR "Container target directory not provided for workflow import"
        return 1
    fi

    if ! docker cp "$staging_dir/." "${container_id}:${container_target_dir}/"; then
        rm -rf "$staging_dir"
        if [[ -n "$manifest_entries_file" ]]; then
            rm -f "$manifest_entries_file"
        fi
        log ERROR "Failed to copy workflows into container directory: $container_target_dir"
        return 1
    fi

    rm -rf "$staging_dir"
    if [[ -n "$manifest_entries_file" ]]; then
        if [[ -n "${RESTORE_MANIFEST_RAW_DEBUG_PATH:-}" && -f "$manifest_entries_file" ]]; then
            if ! cp "$manifest_entries_file" "${RESTORE_MANIFEST_RAW_DEBUG_PATH}" 2>/dev/null; then
                log DEBUG "Unable to persist raw staging manifest to ${RESTORE_MANIFEST_RAW_DEBUG_PATH}"
            else
                log DEBUG "Persisted raw staging manifest to ${RESTORE_MANIFEST_RAW_DEBUG_PATH}"
            fi
        fi
        if [[ -s "$manifest_entries_file" ]]; then
            # Keep NDJSON format - just move to output
            if ! mv "$manifest_entries_file" "$manifest_output" 2>/dev/null; then
                log WARN "Unable to generate staging manifest for workflows; duplicate detection may be limited."
                : > "$manifest_output"
            fi
        else
            : > "$manifest_output"
            rm -f "$manifest_entries_file"
        fi
    fi
    log SUCCESS "Prepared $staged_count workflow file(s) from directory $source_dir for import"
    return 0
}

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