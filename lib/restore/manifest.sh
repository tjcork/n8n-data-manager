#!/usr/bin/env bash
# Manifest reconciliation and folder assignment helpers for restore workflow

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
					| gsub("\\\\\\\"; "/")
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
					| gsub("\\\\\\\"; "/")
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