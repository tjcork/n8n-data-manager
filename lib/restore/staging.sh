#!/usr/bin/env bash
# Workflow and credential staging helpers for restore pipeline

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