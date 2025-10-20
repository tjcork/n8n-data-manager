#!/usr/bin/env bash
# Folder structure synchronization helpers for restore pipeline

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