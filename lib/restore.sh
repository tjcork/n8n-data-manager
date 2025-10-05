#!/usr/bin/env bash
# =========================================================
# lib/restore.sh - Restore operations for n8n-manager
# =========================================================
# All restore-related functions: restore process, rollback

# Source required modules
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

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

    local jq_error=""
    local jq_temp_err
    jq_temp_err=$(mktemp -t n8n-cred-validate-err-XXXXXXXX.log)
    if ! jq empty "$credentials_path" 2>"$jq_temp_err"; then
        local relative_path
        relative_path=$(printf '%s' "$entry" | jq -r '.relativePath // empty' 2>/dev/null)
        local storage_path
        storage_path=$(printf '%s' "$entry" | jq -r '.storagePath // empty' 2>/dev/null)
        log ERROR "Unable to parse credentials file for validation: $credentials_path"
        if [[ -n "$jq_error" ]]; then
            log DEBUG "jq parse error: $jq_error"
        fi
        return 1
    fi
    rm -f "$jq_temp_err"

    local normalized_json
    normalized_json=$(mktemp -t n8n-cred-validate-normalized-XXXXXXXX.json)

    local invalid_entries
    invalid_entries=$(jq -r -f "$invalid_filter_file" "$normalized_json") || invalid_entries=""
    rm -f "$invalid_filter_file"

    if [[ -n "$invalid_entries" ]]; then
        rm -f "$normalized_json"
        log ERROR "Credentials still contain encrypted or invalid data for: $invalid_entries"
        return 1
    fi

    local basic_filter_file
    basic_filter_file=$(mktemp -t n8n-cred-basic-filter-XXXXXXXX.jq)
    cat <<'JQ_FILTER' > "$basic_filter_file"
def safe_credential_value($credential; $field):
    (if ($credential.data // empty) | type == "object" then $credential.data[$field] else empty end)
    // "";

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
    basic_missing=$(jq -r -f "$basic_filter_file" "$normalized_json") || basic_missing=""
    rm -f "$basic_filter_file"

    if [[ -n "$basic_missing" ]]; then
        rm -f "$normalized_json"
        log ERROR "Basic Auth credentials missing username or password: $basic_missing"
        return 1
    fi

    rm -f "$normalized_json" "$jq_temp_err"
    return 0
}

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
    if ! folders_json=$(n8n_api_get_folders 2>&1); then
        if echo "$folders_json" | grep -q "404"; then
            log WARN "Folder structure not supported by this n8n version (HTTP 404). Skipping folder restoration."
            finalize_n8n_api_auth
            return 0
        fi
        finalize_n8n_api_auth
        log ERROR "Failed to fetch folders from n8n API."
        return 1
    fi

    local workflows_json
    if ! workflows_json=$(n8n_api_get_workflows); then
        finalize_n8n_api_auth
        log ERROR "Failed to fetch workflows from n8n API."
        return 1
    fi

    declare -A project_name_map=()
    declare -A project_slug_map=()
    declare -A project_id_map=()
    local default_project_id=""
    local personal_project_id=""

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
        local pslug
        pslug=$(printf '%s' "$project_entry" | jq -r '.slug // empty' 2>/dev/null)
        if [[ -z "$pslug" || "$pslug" == "null" ]]; then
            pslug=$(sanitize_slug "$pname")
        fi
        if [[ -n "$pslug" ]]; then
            project_slug_map["$(printf '%s' "$pslug" | tr '[:upper:]' '[:lower:]')"]="$pid"
        fi
        local ptype
        ptype=$(printf '%s' "$project_entry" | jq -r '.type // empty' 2>/dev/null)
        if [[ -z "$personal_project_id" ]]; then
            if [[ "$ptype" == "personal" ]]; then
                personal_project_id="$pid"
            elif [[ "$key" == "personal" ]]; then
                personal_project_id="$pid"
            fi
        fi
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

    if [[ -n "$personal_project_id" ]]; then
        default_project_id="$personal_project_id"
    fi

    declare -A folder_name_lookup=()
    declare -A folder_slug_lookup=()
    declare -A folder_global_name_lookup=()
    declare -A folder_global_slug_lookup=()
    declare -A folder_parent_lookup=()
    declare -A folder_project_lookup=()
    declare -A folder_slug_by_id=()
    declare -A folder_name_by_id=()
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
        local fname_lower=$(printf '%s' "$fname" | tr '[:upper:]' '[:lower:]')
        local lookup_key="$fproject|$parent_key|$fname_lower"
        folder_name_lookup["$lookup_key"]="$fid"
        local folder_slug
        folder_slug=$(sanitize_slug "$fname")
        if [[ -n "$folder_slug" ]]; then
            local folder_slug_lower=$(printf '%s' "$folder_slug" | tr '[:upper:]' '[:lower:]')
            local slug_key="$fproject|$parent_key|$folder_slug_lower"
            folder_slug_lookup["$slug_key"]="$fid"
            folder_global_slug_lookup["$fproject|$folder_slug_lower"]="$fid"
        fi
        if [[ -n "$fname_lower" ]]; then
            folder_global_name_lookup["$fproject|$fname_lower"]="$fid"
        fi
        folder_parent_lookup["$fid"]="$parent_key"
        folder_project_lookup["$fid"]="$fproject"
        folder_slug_by_id["$fid"]="$folder_slug"
        folder_name_by_id["$fid"]="$fname"
    done < <(printf '%s' "$folders_json" | jq -c 'if type == "array" then .[] else (.data // [])[] end')

    declare -A workflow_version_lookup=()
    declare -A workflow_parent_lookup=()
    declare -A workflow_project_lookup=()
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
        wproject=$(printf '%s' "$workflow_entry" | jq -r '.homeProject.id // .homeProjectId // empty' 2>/dev/null)
        local wparent
        wparent=$(printf '%s' "$workflow_entry" | jq -r '.parentFolderId // (.parentFolder.id // empty)' 2>/dev/null)
        if [[ "$wparent" == "null" ]]; then
            wparent=""
        fi
        workflow_version_lookup["$wid"]="$version_id"
        workflow_parent_lookup["$wid"]="$wparent"
        workflow_project_lookup["$wid"]="$wproject"
    done < <(printf '%s' "$workflows_json" | jq -c 'if type == "array" then .[] else (.data // [])[] end')

    local total_count
    total_count=$(jq -r '.workflows | length' "$manifest_path" 2>/dev/null || echo 0)
    if [[ "$total_count" -eq 0 ]]; then
        finalize_n8n_api_auth
        log INFO "Folder structure manifest empty; nothing to apply."
        return 0
    fi

    local moved_count=0
    local overall_success=true
    local project_created_count=0
    local folder_created_count=0
    local folder_moved_count=0
    local workflow_assignment_count=0

    while IFS= read -r entry; do
        local workflow_id
        workflow_id=$(printf '%s' "$entry" | jq -r '.id // empty' 2>/dev/null)
        local workflow_name
        workflow_name=$(printf '%s' "$entry" | jq -r '.name // "Workflow"' 2>/dev/null)
        local display_path
        display_path=$(printf '%s' "$entry" | jq -r '.displayPath // empty' 2>/dev/null)

        local storage_path
        storage_path=$(printf '%s' "$entry" | jq -r '.storagePath // empty' 2>/dev/null)
        local relative_path_entry
        relative_path_entry=$(printf '%s' "$entry" | jq -r '.relativePath // empty' 2>/dev/null)
        local effective_storage_path="$storage_path"
        if [[ -z "$effective_storage_path" || "$effective_storage_path" == "null" ]]; then
            effective_storage_path="$(apply_github_path_prefix "$relative_path_entry")"
        fi

        if ! path_matches_github_prefix "$effective_storage_path"; then
            log DEBUG "Skipping workflow ${workflow_id:-unknown} outside configured GITHUB_PATH prefix"
            continue
        fi

        local project_name
        project_name=$(printf '%s' "$entry" | jq -r '.project.name // empty' 2>/dev/null)
        local project_id_manifest
        project_id_manifest=$(printf '%s' "$entry" | jq -r '.project.id // empty' 2>/dev/null)
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

        if [[ -z "$target_project_id" && -n "$project_id_manifest" && -n "${project_id_map[$project_id_manifest]+set}" ]]; then
            target_project_id="$project_id_manifest"
        fi

        if [[ -z "$target_project_id" && -n "$project_name" ]]; then
            local project_key
            project_key=$(printf '%s' "$project_name" | tr '[:upper:]' '[:lower:]')
            if [[ -n "${project_name_map[$project_key]+set}" ]]; then
                target_project_id="${project_name_map[$project_key]}"
            fi
        fi

        if [[ -z "$target_project_id" ]]; then
            target_project_id="$default_project_id"
            if [[ -n "$project_name" && "$project_name" != "null" ]]; then
                log INFO "Mapping manifest project '$project_name' to default personal project for workflow '$workflow_name'."
            elif [[ -n "$project_slug" && "$project_slug" != "null" ]]; then
                log INFO "Mapping manifest project slug '$project_slug' to default personal project for workflow '$workflow_name'."
            fi
        fi

        local -a folder_entries=()
        while IFS= read -r folder_obj; do
            if [[ -n "$folder_obj" && "$folder_obj" != "null" ]]; then
                folder_entries+=("$folder_obj")
            fi
        done < <(printf '%s' "$entry" | jq -c '.folders[]?' 2>/dev/null)

        local parent_folder_id=""
        local folder_failure=false

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
            local folder_name_lower=""
            [[ -n "$folder_name" && "$folder_name" != "null" ]] && folder_name_lower=$(printf '%s' "$folder_name" | tr '[:upper:]' '[:lower:]')
            local folder_slug_lower=""
            [[ -n "$folder_slug" && "$folder_slug" != "null" ]] && folder_slug_lower=$(printf '%s' "$folder_slug" | tr '[:upper:]' '[:lower:]')

            local slug_key=""
            [[ -n "$folder_slug_lower" ]] && slug_key="$target_project_id|$parent_key|$folder_slug_lower"
            local lookup_key=""
            [[ -n "$folder_name_lower" ]] && lookup_key="$target_project_id|$parent_key|$folder_name_lower"
            local global_slug_key=""
            [[ -n "$folder_slug_lower" ]] && global_slug_key="$target_project_id|$folder_slug_lower"
            local global_name_key=""
            [[ -n "$folder_name_lower" ]] && global_name_key="$target_project_id|$folder_name_lower"

            local existing_folder_id=""
            if [[ -n "$slug_key" && -n "${folder_slug_lookup["$slug_key"]+set}" ]]; then
                existing_folder_id="${folder_slug_lookup["$slug_key"]}"
            elif [[ -n "$lookup_key" && -n "${folder_name_lookup["$lookup_key"]+set}" ]]; then
                existing_folder_id="${folder_name_lookup["$lookup_key"]}"
            fi

            if [[ -z "$existing_folder_id" ]]; then
                local global_candidate=""
                if [[ -n "$global_slug_key" && -n "${folder_global_slug_lookup["$global_slug_key"]+set}" ]]; then
                    global_candidate="${folder_global_slug_lookup["$global_slug_key"]}"
                elif [[ -n "$global_name_key" && -n "${folder_global_name_lookup["$global_name_key"]+set}" ]]; then
                    global_candidate="${folder_global_name_lookup["$global_name_key"]}"
                fi

                if [[ -n "$global_candidate" ]]; then
                    local candidate_project="${folder_project_lookup[$global_candidate]:-}"
                    if [[ -n "$candidate_project" && "$candidate_project" != "$target_project_id" ]]; then
                        global_candidate=""
                    fi
                fi

                if [[ -n "$global_candidate" ]]; then
                    local move_project="${folder_project_lookup[$global_candidate]:-$target_project_id}"
                    local current_parent="${folder_parent_lookup[$global_candidate]:-root}"
                    if [[ "$current_parent" != "$parent_key" ]]; then
                        if ! n8n_api_update_folder_parent "$move_project" "$global_candidate" "$parent_folder_id"; then
                            log ERROR "Failed to move existing folder '${folder_name:-$folder_slug}' into expected hierarchy"
                            folder_failure=true
                            break
                        fi
                        local old_slug="${folder_slug_by_id[$global_candidate]:-}"
                        local old_name="${folder_name_by_id[$global_candidate]:-}"
                        if [[ -n "$old_slug" ]]; then
                            local old_slug_lower=$(printf '%s' "$old_slug" | tr '[:upper:]' '[:lower:]')
                            local old_slug_key="$move_project|$current_parent|$old_slug_lower"
                            unset "folder_slug_lookup[$old_slug_key]"
                        fi
                        if [[ -n "$old_name" ]]; then
                            local old_name_lower=$(printf '%s' "$old_name" | tr '[:upper:]' '[:lower:]')
                            local old_name_key="$move_project|$current_parent|$old_name_lower"
                            unset "folder_name_lookup[$old_name_key]"
                        fi
                        folder_parent_lookup["$global_candidate"]="$parent_key"
                        folder_project_lookup["$global_candidate"]="$target_project_id"
                        log INFO "Moved existing n8n folder '${folder_name:-$folder_slug}' to new parent"
                        folder_moved_count=$((folder_moved_count + 1))
                    fi
                    existing_folder_id="$global_candidate"
                fi
            fi

            if [[ -z "$existing_folder_id" ]]; then
                local create_name="$folder_name"
                if [[ -z "$create_name" ]]; then
                    create_name=$(unslug_to_title "$folder_slug")
                fi
                local create_response
                if ! create_response=$(n8n_api_create_folder "$create_name" "$target_project_id" "$parent_folder_id"); then
                    log ERROR "Failed to create folder '$create_name' in project '${project_id_map[$target_project_id]:-Default}'"
                    folder_failure=true
                    break
                fi
                local create_data
                create_data=$(printf '%s' "$create_response" | jq '.data // .' 2>/dev/null)
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
                response_parent=$(printf '%s' "$create_data" | jq -r '.parentFolderId // empty' 2>/dev/null)
                if [[ "$response_parent" == "null" ]]; then
                    response_parent=""
                fi
                parent_key="${response_parent:-root}"
                folder_parent_lookup["$existing_folder_id"]="$parent_key"
                folder_project_lookup["$existing_folder_id"]="$target_project_id"
                folder_slug_by_id["$existing_folder_id"]="$folder_slug"
                folder_name_by_id["$existing_folder_id"]="$folder_name"
                log INFO "Created n8n folder '$create_name' in project '${project_id_map[$target_project_id]:-Default}'"
                folder_created_count=$((folder_created_count + 1))
            fi

            # Recompute lower-case keys in case name or slug changed (e.g. after creation)
            folder_name_lower=""
            [[ -n "$folder_name" && "$folder_name" != "null" ]] && folder_name_lower=$(printf '%s' "$folder_name" | tr '[:upper:]' '[:lower:]')
            folder_slug_lower=""
            [[ -n "$folder_slug" && "$folder_slug" != "null" ]] && folder_slug_lower=$(printf '%s' "$folder_slug" | tr '[:upper:]' '[:lower:]')
            slug_key=""
            [[ -n "$folder_slug_lower" ]] && slug_key="$target_project_id|$parent_key|$folder_slug_lower"
            lookup_key=""
            [[ -n "$folder_name_lower" ]] && lookup_key="$target_project_id|$parent_key|$folder_name_lower"
            global_slug_key=""
            [[ -n "$folder_slug_lower" ]] && global_slug_key="$target_project_id|$folder_slug_lower"
            global_name_key=""
            [[ -n "$folder_name_lower" ]] && global_name_key="$target_project_id|$folder_name_lower"

            if [[ -n "$lookup_key" ]]; then
                folder_name_lookup["$lookup_key"]="$existing_folder_id"
            fi
            if [[ -n "$slug_key" ]]; then
                folder_slug_lookup["$slug_key"]="$existing_folder_id"
            fi
            if [[ -n "$global_name_key" ]]; then
                folder_global_name_lookup["$global_name_key"]="$existing_folder_id"
            fi
            if [[ -n "$global_slug_key" ]]; then
                folder_global_slug_lookup["$global_slug_key"]="$existing_folder_id"
            fi

            parent_folder_id="$existing_folder_id"
        done

        if $folder_failure; then
            overall_success=false
            continue
        fi

        local assignment_folder_id="${parent_folder_id:-}"
        local current_project="${workflow_project_lookup[$workflow_id]:-}"
        local current_parent="${workflow_parent_lookup[$workflow_id]:-}"
        local version_id="${workflow_version_lookup[$workflow_id]:-}"

        if [[ -z "$workflow_id" ]]; then
            overall_success=false
            log WARN "Manifest entry missing workflow ID; skipping."
            continue
        fi

        if [[ -z "$version_id" || "$version_id" == "null" ]]; then
            overall_success=false
            log WARN "Unable to determine current version for workflow '$workflow_name' ($workflow_id); skipping reassignment."
            continue
        fi

        local normalized_assignment="${assignment_folder_id:-}"
        local normalized_current="${current_parent:-}"
        if [[ "${normalized_current:-}" == "null" ]]; then
            normalized_current=""
        fi

        if [[ "${normalized_assignment:-}" == "null" ]]; then
            normalized_assignment=""
        fi

        if [[ "$current_project" == "$target_project_id" && "$normalized_current" == "$normalized_assignment" ]]; then
            log DEBUG "Workflow '$workflow_name' ($workflow_id) already in desired project/folder; skipping update."
            continue
        fi

        if ! n8n_api_update_workflow_assignment "$workflow_id" "$target_project_id" "$assignment_folder_id" "$version_id"; then
            log WARN "Failed to assign workflow '$workflow_name' ($workflow_id) to target folder structure."
            overall_success=false
            continue
        fi

        workflow_project_lookup["$workflow_id"]="$target_project_id"
        workflow_parent_lookup["$workflow_id"]="$assignment_folder_id"
        moved_count=$((moved_count + 1))
        workflow_assignment_count=$((workflow_assignment_count + 1))
    done < <(jq -c '.workflows[]' "$manifest_path" 2>/dev/null)

    finalize_n8n_api_auth

    log INFO "Folder synchronization summary: ${project_created_count} project(s) created, ${folder_created_count} folder(s) created, ${folder_moved_count} folder(s) repositioned, ${workflow_assignment_count} workflow(s) reassigned."

    if ! $overall_success; then
        log WARN "Folder structure restoration completed with warnings (${moved_count}/${total_count} workflows updated)."
        return 1
    fi

    log SUCCESS "Folder structure restored for $moved_count workflow(s)."
    return 0
}

copy_manifest_workflows_to_container() {
    local manifest_path="$1"
    local manifest_base="$2"
    local container_id="$3"
    local container_target_dir="$4"

    if [[ ! -f "$manifest_path" ]]; then
        log ERROR "Folder structure manifest missing: $manifest_path"
        return 1
    fi

    if [[ -z "$manifest_base" || ! -d "$manifest_base" ]]; then
        manifest_base="$(dirname "$manifest_path")"
        if [[ ! -d "$manifest_base" ]]; then
            log ERROR "Manifest base directory not found for structured workflows: $manifest_base"
            return 1
        fi
    fi

    local staging_dir
    staging_dir=$(mktemp -d -t n8n-structured-import-XXXXXXXXXX)
    local copy_success=true
    local staged_count=0
    local entry_index=0

    while IFS= read -r entry; do
        entry_index=$((entry_index + 1))

        local filename
        filename=$(printf '%s' "$entry" | jq -r '.filename // empty' 2>/dev/null)
        local workflow_id
        workflow_id=$(printf '%s' "$entry" | jq -r '.id // empty' 2>/dev/null)
        local relative_path
        relative_path=$(printf '%s' "$entry" | jq -r '.relativePath // empty' 2>/dev/null)
        local storage_path
        storage_path=$(printf '%s' "$entry" | jq -r '.storagePath // empty' 2>/dev/null)

        if [[ -z "$filename" || "$filename" == "null" ]]; then
            log WARN "Manifest entry $entry_index missing filename; skipping"
            copy_success=false
            continue
        fi

        if [[ "$relative_path" == "null" ]]; then
            relative_path=""
        fi

        local effective_storage_path="$storage_path"
        if [[ -z "$effective_storage_path" || "$effective_storage_path" == "null" ]]; then
            effective_storage_path="$(apply_github_path_prefix "$relative_path")"
        fi

        if ! path_matches_github_prefix "$effective_storage_path"; then
            log DEBUG "Skipping manifest entry $entry_index outside configured GITHUB_PATH prefix"
            continue
        fi

        local sanitized_storage="${effective_storage_path#/}"
        sanitized_storage="${sanitized_storage%/}"

        if [[ "$sanitized_storage" == *".."* ]]; then
            log WARN "Skipping manifest entry $entry_index due to unsafe storage path: $sanitized_storage"
            copy_success=false
            continue
        fi

        local source_dir="$manifest_base"
        if [[ -n "$sanitized_storage" ]]; then
            source_dir="$source_dir/$sanitized_storage"
        fi

        local source_path="$source_dir/$filename"
        if [[ ! -f "$source_path" ]]; then
            log ERROR "Workflow file from manifest not found: $source_path"
            copy_success=false
            continue
        fi

        local dest_basename=""
        if [[ -n "$workflow_id" && "$workflow_id" != "null" ]]; then
            dest_basename="$workflow_id"
        else
            dest_basename="${filename%.json}"
        fi

        local dest_filename="${dest_basename}.json"
        local suffix=1
        while [[ -e "$staging_dir/$dest_filename" ]]; do
            dest_filename="${dest_basename}_${suffix}.json"
            suffix=$((suffix + 1))
        done

        if ! cp "$source_path" "$staging_dir/$dest_filename"; then
            log ERROR "Failed to stage workflow file: $source_path"
            copy_success=false
            continue
        fi

        staged_count=$((staged_count + 1))
    done < <(jq -c '.workflows[]' "$manifest_path" 2>/dev/null)

    if [[ "$staged_count" -eq 0 ]]; then
        rm -rf "$staging_dir"
        log ERROR "No workflow files could be staged from manifest: $manifest_path"
        return 1
    fi

    if ! $copy_success; then
        rm -rf "$staging_dir"
        return 1
    fi

    if [[ -z "$container_target_dir" ]]; then
        rm -rf "$staging_dir"
        log ERROR "Container target directory not provided for structured workflow import"
        return 1
    fi

    if ! docker cp "$staging_dir/." "${container_id}:${container_target_dir}/"; then
        rm -rf "$staging_dir"
        log ERROR "Failed to copy structured workflows into container directory: $container_target_dir"
        return 1
    fi

    rm -rf "$staging_dir"
    log SUCCESS "Prepared $staged_count structured workflow file(s) for import"
    return 0
}

generate_folder_manifest_from_directory() {
    local source_dir="$1"
    local output_path="$2"

    if [[ -z "$source_dir" || ! -d "$source_dir" ]]; then
        log ERROR "Cannot derive folder structure manifest - directory missing: ${source_dir:-<empty>}"
        return 1
    fi

    if [[ -z "$output_path" ]]; then
        log ERROR "Output path not provided for generated folder structure manifest"
        return 1
    fi

    local entries_file
    entries_file=$(mktemp -t n8n-folder-entries-XXXXXXXX.json)
    printf '[]' > "$entries_file"

    local success=true
    local processed=0

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

        local storage_path="$relative_dir"
        storage_path="${storage_path#/}"
        storage_path="${storage_path%/}"

        local relative_dir_without_prefix
        relative_dir_without_prefix="$(strip_github_path_prefix "$storage_path")"
        relative_dir_without_prefix="${relative_dir_without_prefix#/}"
        relative_dir_without_prefix="${relative_dir_without_prefix%/}"

        local workflow_id
        workflow_id=$(jq -r '.id // empty' "$workflow_file" 2>/dev/null)
        if [[ -z "$workflow_id" ]]; then
            log WARN "Skipping workflow without ID when deriving folder manifest: $workflow_file"
            success=false
            continue
        fi

        local workflow_name
        workflow_name=$(jq -r '.name // "Unnamed Workflow"' "$workflow_file" 2>/dev/null)

        local -a path_parts=()
        if [[ -n "$relative_dir_without_prefix" ]]; then
            IFS='/' read -r -a path_parts <<< "$relative_dir_without_prefix"
        fi

        local -a slug_parts=()
        if ((${#path_parts[@]} > 0)); then
            local original_segment
            for original_segment in "${path_parts[@]}"; do
                local segment_slug
                segment_slug=$(sanitize_slug "$original_segment")
                if [[ -z "$segment_slug" ]]; then
                    segment_slug=$(sanitize_slug "$(unslug_to_title "$original_segment")")
                fi
                if [[ -z "$segment_slug" ]]; then
                    segment_slug="Folder"
                fi
                slug_parts+=("$segment_slug")
            done
        fi

        local project_slug=""
        if ((${#slug_parts[@]} > 0)); then
            project_slug="${slug_parts[0]}"
        fi
        if [[ -z "$project_slug" ]]; then
            project_slug="Personal"
        fi

        local -a folder_slugs=()
        if ((${#slug_parts[@]} > 1)); then
            folder_slugs=("${slug_parts[@]:1}")
        fi

    local relative_path="$relative_dir_without_prefix"

        local project_name
        project_name=$(unslug_to_title "$project_slug")

        local display_path=""
        if ((${#slug_parts[@]} > 0)); then
            local display_segments=()
            local slug_value
            for slug_value in "${slug_parts[@]}"; do
                display_segments+=("$(unslug_to_title "$slug_value")")
            done
            display_path=$(IFS=/; printf '%s' "${display_segments[*]}")
        else
            display_path="$project_name"
        fi

        local folder_array_json='[]'
        if ((${#folder_slugs[@]} > 0)); then
            local folder_temp
            folder_temp=$(mktemp -t n8n-folder-array-XXXXXXXX.json)
            printf '[]' > "$folder_temp"
            local slug
            for slug in "${folder_slugs[@]}"; do
                [[ -z "$slug" ]] && continue
                local folder_name
                folder_name=$(unslug_to_title "$slug")
                local folder_entry
                folder_entry=$(jq -n --arg name "$folder_name" --arg slug "$slug" '{name: $name, slug: $slug}')
                jq --argjson entry "$folder_entry" '. + [$entry]' "$folder_temp" > "${folder_temp}.tmp"
                mv "${folder_temp}.tmp" "$folder_temp"
            done
            folder_array_json=$(cat "$folder_temp")
            rm -f "$folder_temp"
        fi

        local entry_json
        entry_json=$(jq -n \
            --arg id "$workflow_id" \
            --arg name "$workflow_name" \
            --arg filename "$filename" \
            --arg relative "$relative_path" \
            --arg storage "$storage_path" \
            --arg display "$display_path" \
            --arg projectSlug "$project_slug" \
            --arg projectName "$project_name" \
            --argjson folders "$folder_array_json" \
            '{
                id: $id,
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
                folders: $folders
            }')

        jq --argjson entry "$entry_json" '. + [$entry]' "$entries_file" > "${entries_file}.tmp"
        mv "${entries_file}.tmp" "$entries_file"
        processed=$((processed + 1))
    done < <(find "$source_dir" -type f -name "*.json" \
        ! -path "*/.credentials/*" \
        ! -name "credentials.json" \
        ! -name "workflows.json" \
        ! -name ".n8n-folder-structure.json" -print0)

    if (( processed == 0 )); then
        rm -f "$entries_file"
        log ERROR "No workflow files found when building folder structure manifest from $source_dir"
        return 1
    fi

    local manifest_payload
    manifest_payload=$(jq -n \
        --arg exportedAt "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --arg source "n8n-data-manager" \
        --argjson workflows "$(cat "$entries_file")" \
        '{
            version: 1,
            exportedAt: $exportedAt,
            source: $source,
            workflows: $workflows
        }')

    printf '%s\n' "$manifest_payload" > "$output_path"

    rm -f "$entries_file"

    if ! $success; then
        log WARN "Generated folder structure manifest with warnings. Some workflows may lack folder metadata."
    fi

    log INFO "Generated folder structure manifest at $output_path by scanning directory structure."
    return 0
}

stage_directory_workflows_to_container() {
    local source_dir="$1"
    local container_id="$2"
    local container_target_dir="$3"

    if [[ -z "$source_dir" || ! -d "$source_dir" ]]; then
        log ERROR "Structured workflow directory not found: ${source_dir:-<empty>}"
        return 1
    fi

    local staging_dir
    staging_dir=$(mktemp -d -t n8n-structured-import-XXXXXXXXXX)
    local copy_success=true
    local staged_count=0

    while IFS= read -r -d '' workflow_file; do
        local filename
        filename=$(basename "$workflow_file")

        if [[ -z "$filename" || "$filename" == ".json" ]]; then
            filename="workflow_${staged_count}.json"
        fi

        local dest_filename="$filename"
        local base_name="${filename%.json}"
        local suffix=1
        while [[ -e "$staging_dir/$dest_filename" ]]; do
            dest_filename="${base_name}_${suffix}.json"
            suffix=$((suffix + 1))
        done

        if ! cp "$workflow_file" "$staging_dir/$dest_filename"; then
            log WARN "Failed to stage workflow file: $workflow_file"
            copy_success=false
            continue
        fi

        staged_count=$((staged_count + 1))
    done < <(find "$source_dir" -type f -name "*.json" \
        ! -path "*/.credentials/*" \
        ! -path "*/archive/*" \
        ! -name "credentials.json" \
        ! -name ".n8n-folder-structure.json" -print0)

    if [[ "$staged_count" -eq 0 ]]; then
        rm -rf "$staging_dir"
        log ERROR "No workflow JSON files found in directory: $source_dir"
        return 1
    fi

    if ! $copy_success; then
        rm -rf "$staging_dir"
        return 1
    fi

    if [[ -z "$container_target_dir" ]]; then
        rm -rf "$staging_dir"
        log ERROR "Container target directory not provided for structured workflow import"
        return 1
    fi

    if ! docker cp "$staging_dir/." "${container_id}:${container_target_dir}/"; then
        rm -rf "$staging_dir"
        log ERROR "Failed to copy structured workflows into container directory: $container_target_dir"
        return 1
    fi

    rm -rf "$staging_dir"
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
    local apply_folder_structure="${7:-false}"
    local is_dry_run=${8:-false}
    local credentials_folder_name="${9:-.credentials}"
    local folder_structure_backup=false
    local folder_manifest_path=""
    local folder_manifest_base=""
    local folder_manifest_available=false
    local generated_manifest_path=""
    local download_dir=""
    local repo_workflows=""
    local structured_workflows_dir=""
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
    local credentials_git_relative_dir
    credentials_git_relative_dir="$(apply_github_path_prefix "$credentials_folder_name")"
    if [[ -z "$credentials_git_relative_dir" ]]; then
        credentials_git_relative_dir="$credentials_folder_name"
    fi
    local credentials_subpath="$credentials_git_relative_dir/credentials.json"

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
        log INFO "Cloning repository $github_repo branch $branch..."
        log DEBUG "Running: git clone --depth 1 --branch $branch $git_repo_url $download_dir"
        if ! git clone --depth 1 --branch "$branch" "$git_repo_url" "$download_dir"; then
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
                folder_manifest_path="$selected_base_dir/.n8n-folder-structure.json"
                folder_manifest_base="$(dirname "$folder_manifest_path")"
                folder_manifest_available=true
                structured_workflows_dir="$folder_manifest_base"
                log INFO "Detected folder structure manifest: $folder_manifest_path"
            else
                local manifest_candidate
                manifest_candidate=$(find "$selected_base_dir" -maxdepth 5 -type f -name ".n8n-folder-structure.json" | head -n 1)
                if [[ -n "$manifest_candidate" ]]; then
                    folder_structure_backup=true
                    folder_manifest_path="$manifest_candidate"
                    folder_manifest_base="$(dirname "$manifest_candidate")"
                    folder_manifest_available=true
                    structured_workflows_dir="$folder_manifest_base"
                    log INFO "Detected folder structure manifest: $folder_manifest_path"
                fi
            fi

            if ! $folder_structure_backup; then
                if [ -f "$selected_base_dir/workflows.json" ]; then
                    repo_workflows="$selected_base_dir/workflows.json"
                    log SUCCESS "Found workflows.json in selected backup"
                elif [ -f "$download_dir/workflows.json" ]; then
                    repo_workflows="$download_dir/workflows.json"
                    log SUCCESS "Found workflows.json in repository root"
                else
                    local separated_hint=""
                    if [ -d "$selected_base_dir/workflows" ] && find "$selected_base_dir/workflows" -type f -name "*.json" -print -quit >/dev/null 2>&1; then
                        separated_hint="$selected_base_dir/workflows"
                    else
                        local candidate_file
                        candidate_file=$(find "$selected_base_dir" -mindepth 1 -maxdepth 4 -type f -name "*.json" \
                            ! -path "*/.credentials/*" \
                            ! -name "credentials.json" \
                            ! -name "workflows.json" \
                            -print -quit 2>/dev/null || true)
                        if [[ -n "$candidate_file" ]]; then
                            separated_hint="$(dirname "$candidate_file")"
                        fi
                    fi

                    if [[ -n "$separated_hint" ]]; then
                        folder_structure_backup=true
                        folder_manifest_available=false
                        structured_workflows_dir="$selected_base_dir"
                        log WARN "Folder structure manifest not found. Falling back to directory import using separated workflow files (example path: $separated_hint)"
                    fi
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
        if [ -f "$local_backup_dir/.n8n-folder-structure.json" ]; then
            folder_structure_backup=true
            folder_manifest_path="$local_backup_dir/.n8n-folder-structure.json"
            folder_manifest_base="$(dirname "$folder_manifest_path")"
            folder_manifest_available=true
            structured_workflows_dir="$folder_manifest_base"
            log INFO "Detected local folder structure manifest: $folder_manifest_path"
        else
            if [ -f "$local_workflows_file" ]; then
                repo_workflows="$local_workflows_file"
                log INFO "Selected local workflows backup: $repo_workflows"
            elif find "$local_backup_dir" -type f -name "*.json" ! -path "*/.credentials/*" ! -name "credentials.json" ! -name "workflows.json" -print -quit >/dev/null 2>&1; then
                folder_structure_backup=true
                folder_manifest_available=false
                structured_workflows_dir="$local_backup_dir"
                log WARN "Local workflows.json not found. Falling back to directory import using separated workflow files in $local_backup_dir"
            else
                log WARN "Local workflows.json not found and no separated workflow files detected in $local_backup_dir"
            fi
        fi
    fi

    if [[ "$credentials_mode" == "1" ]]; then
        repo_credentials="$local_credentials_file"
        log INFO "Selected local credentials backup: $repo_credentials"
    fi

    if $folder_structure_backup && $folder_manifest_available; then
        if [[ -z "$folder_manifest_base" || ! -d "$folder_manifest_base" ]]; then
            folder_manifest_base="$(dirname "$folder_manifest_path")"
        fi
    fi

    # Validate files before proceeding
    log INFO "Validating files for import..."
    local file_validation_passed=true
    
    if [[ "$workflows_mode" != "0" ]]; then
        if $folder_structure_backup; then
            if $folder_manifest_available; then
                if ! jq -e '.workflows | length > 0' "$folder_manifest_path" >/dev/null 2>&1; then
                    log ERROR "Folder structure manifest is invalid or empty: $folder_manifest_path"
                    file_validation_passed=false
                else
                    local manifest_count
                    manifest_count=$(jq -r '.workflows | length' "$folder_manifest_path" 2>/dev/null || echo 0)
                    log SUCCESS "Folder structure manifest validated ($manifest_count workflow file(s) detected)"
                fi
            else
                if [[ -z "$structured_workflows_dir" || ! -d "$structured_workflows_dir" ]]; then
                    log ERROR "Structured workflow directory not found for import"
                    file_validation_passed=false
                else
                    local validation_dir="$structured_workflows_dir"
                    if [[ -n "$github_path" ]]; then
                        validation_dir="$(resolve_github_storage_root "$validation_dir")"
                    fi

                    if [[ -z "$validation_dir" || ! -d "$validation_dir" ]]; then
                        log ERROR "Structured workflow directory for configured GITHUB_PATH not found"
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

    if [[ "$workflows_mode" != "0" ]] && $folder_structure_backup && ! $folder_manifest_available && [[ "$apply_folder_structure" == "true" ]] && [ "$file_validation_passed" = "true" ]; then
        if [[ -n "$structured_workflows_dir" && -d "$structured_workflows_dir" ]]; then
            generated_manifest_path=$(mktemp -t n8n-generated-manifest-XXXXXXXX.json)
            if generate_folder_manifest_from_directory "$structured_workflows_dir" "$generated_manifest_path"; then
                folder_manifest_path="$generated_manifest_path"
                folder_manifest_base="$structured_workflows_dir"
                folder_manifest_available=true
                log INFO "Derived folder structure manifest from directory layout"
            else
                rm -f "$generated_manifest_path"
                generated_manifest_path=""
                log WARN "Unable to derive folder structure manifest from directory layout. Folder assignments may need manual update."
            fi
        else
            log WARN "Structured workflow directory unavailable; cannot derive folder structure manifest automatically."
        fi
    fi
    
    if [ "$file_validation_passed" != "true" ]; then
        log ERROR "File validation failed. Cannot proceed with restore."
        if [[ -n "$download_dir" ]]; then
            rm -rf "$download_dir"
        fi
        return 1
    fi
    
    # --- 2. Import Data ---
    log HEADER "Step 2: Importing Data into n8n"
    
    local pre_import_workflow_count=0
    if [[ "$workflows_mode" != "0" ]] && [ "$is_dry_run" != "true" ]; then
        local count_output
        count_output=$(docker exec "$container_id" sh -c "n8n export:workflow --all --output=/tmp/pre_count.json 2>&1" || echo "")
        if [[ -n "$count_output" ]] && ! echo "$count_output" | grep -q "Error\|No workflows"; then
            pre_import_workflow_count=$(docker exec "$container_id" sh -c "cat /tmp/pre_count.json 2>/dev/null | jq 'length' 2>/dev/null || echo 0")
            docker exec "$container_id" sh -c "rm -f /tmp/pre_count.json" 2>/dev/null || true
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
    if [[ "$credentials_mode" != "0" ]]; then
        # Only attempt decryption if not a dry run and file is not empty
        if [ "$is_dry_run" != "true" ] && [ -s "$repo_credentials" ]; then
            # Check if file appears to be encrypted (any credential with string data)
            if jq -e '[.[] | select(has("data") and (.data | type == "string"))] | length > 0' "$repo_credentials" >/dev/null 2>&1; then
                log INFO "Encrypted credentials detected. Decrypting before import..."
                decrypt_tmpfile="$(mktemp -t n8n-decrypted-XXXXXXXX.json)"
                # Prompt for key and decrypt using lib/decrypt.sh
                local decrypt_lib="$(dirname "${BASH_SOURCE[0]}")/decrypt.sh"
                if [[ ! -f "$decrypt_lib" ]]; then
                    log ERROR "Decrypt helper not found at $decrypt_lib"
                    rm -f "$decrypt_tmpfile"
                    if [[ -n "$download_dir" ]]; then
                        rm -rf "$download_dir"
                    fi
                    return 1
                fi
                # shellcheck source=lib/decrypt.sh
                source "$decrypt_lib"
                check_dependencies
                local decryption_key
                local prompt_device="/dev/tty"
                if [[ ! -r "$prompt_device" ]]; then
                    prompt_device="/proc/self/fd/2"
                fi
                if ! read -r -s -p "Enter encryption key for credentials decryption: " decryption_key <"$prompt_device"; then
                    printf '\n' >"$prompt_device" 2>/dev/null || true
                    log ERROR "Unable to read encryption key from terminal."
                    rm -f "$decrypt_tmpfile"
                    if [[ -n "$download_dir" ]]; then
                        rm -rf "$download_dir"
                    fi
                    return 1
                fi
                printf '\n' >"$prompt_device" 2>/dev/null || echo >&2
                if decrypt_credentials_file "$decryption_key" "$repo_credentials" "$decrypt_tmpfile"; then
                    if ! validate_credentials_payload "$decrypt_tmpfile"; then
                        log ERROR "Decrypted credentials failed validation. Aborting restore."
                        rm -f "$decrypt_tmpfile"
                        if [[ -n "$download_dir" ]]; then
                            rm -rf "$download_dir"
                        fi
                        return 1
                    fi
                    log SUCCESS "Credentials decrypted successfully."
                    credentials_to_import="$decrypt_tmpfile"
                else
                    log ERROR "Failed to decrypt credentials. Aborting restore."
                    rm -f "$decrypt_tmpfile"
                    if [[ -n "$download_dir" ]]; then
                        rm -rf "$download_dir"
                    fi
                    return 1
                fi
            fi
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

    # Copy workflow file if needed
    if [[ "$workflows_mode" != "0" ]]; then
        if $folder_structure_backup; then
            if [ "$is_dry_run" = "true" ]; then
                if $folder_manifest_available; then
                    log DRYRUN "Would stage structured workflows in ${container_import_workflows} using manifest $folder_manifest_path"
                else
                    local stage_source_dir="$structured_workflows_dir"
                    if [[ -n "$github_path" ]]; then
                        stage_source_dir="$(resolve_github_storage_root "$stage_source_dir")"
                    fi
                    log DRYRUN "Would stage structured workflows in ${container_import_workflows} by scanning directory $stage_source_dir"
                fi
            else
                if ! dockExec "$container_id" "rm -rf $container_import_workflows && mkdir -p $container_import_workflows" false; then
                    log ERROR "Failed to prepare container directory for structured workflow import."
                    copy_status="failed"
                else
                    if $folder_manifest_available; then
                        if ! copy_manifest_workflows_to_container "$folder_manifest_path" "$folder_manifest_base" "$container_id" "$container_import_workflows"; then
                            log ERROR "Failed to copy structured workflow files into container."
                            copy_status="failed"
                        else
                            log SUCCESS "Structured workflow files prepared in container directory $container_import_workflows"
                        fi
                    else
                        local stage_source_dir="$structured_workflows_dir"
                        if [[ -n "$github_path" ]]; then
                            stage_source_dir="$(resolve_github_storage_root "$stage_source_dir")"
                        fi
                        if [[ -z "$stage_source_dir" || ! -d "$stage_source_dir" ]]; then
                            log ERROR "Structured workflow directory not found for prefix-filtered import: ${stage_source_dir:-<empty>}"
                            copy_status="failed"
                        elif ! stage_directory_workflows_to_container "$stage_source_dir" "$container_id" "$container_import_workflows"; then
                            log ERROR "Failed to copy structured workflow files into container."
                            copy_status="failed"
                        else
                            log SUCCESS "Structured workflow files prepared in container directory $container_import_workflows"
                        fi
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
        if [[ -n "$generated_manifest_path" ]]; then
            rm -f "$generated_manifest_path"
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
                log DRYRUN "Would enumerate structured workflow JSON files under $container_import_workflows and import each individually"
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
                        log SUCCESS "Imported $imported_count structured workflow file(s)"
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
    
    if [[ "$workflows_mode" != "0" ]] && $folder_structure_backup && $folder_manifest_available && [ "$is_dry_run" != "true" ] && [ "$import_status" != "failed" ] && [[ "$apply_folder_structure" == "true" ]]; then
        if ! apply_folder_structure_from_manifest "$folder_manifest_path" "$container_id" "$is_dry_run" ""; then
            log WARN "Folder structure restoration encountered issues; workflows may require manual reorganization."
        fi
    fi

    if [[ -n "$generated_manifest_path" ]]; then
        rm -f "$generated_manifest_path"
    fi

    # Clean up temporary files in container
    if [ "$is_dry_run" != "true" ]; then
        log INFO "Cleaning up temporary files in container..."
    dockExecAsRoot "$container_id" "rm -rf $container_import_workflows $container_import_credentials 2>/dev/null || true" "$is_dry_run" || true
    fi
    
    # Clean up downloaded repository
    if [[ -n "$download_dir" ]]; then
        rm -rf "$download_dir"
    fi
    
    # Handle restore result
    if [ "$import_status" = "failed" ]; then
        log WARN "Restore partially completed with some errors. Check logs for details."
        return 1
    fi
    
    # Report workflow import results
    if [[ "$workflows_mode" != "0" ]] && [ "$is_dry_run" != "true" ]; then
        local post_import_workflow_count=0
        local count_output
        count_output=$(docker exec "$container_id" sh -c "n8n export:workflow --all --output=/tmp/post_count.json 2>&1" || echo "")
        if [[ -n "$count_output" ]] && ! echo "$count_output" | grep -q "Error"; then
            post_import_workflow_count=$(docker exec "$container_id" sh -c "cat /tmp/post_count.json 2>/dev/null | jq 'length' 2>/dev/null || echo 0")
            docker exec "$container_id" sh -c "rm -f /tmp/post_count.json" 2>/dev/null || true
        fi
        
        local newly_added=$((post_import_workflow_count - pre_import_workflow_count))
        if [[ $newly_added -gt 0 ]]; then
            log SUCCESS "Imported $newly_added new workflow(s). Total workflows in instance: $post_import_workflow_count"
        elif [[ $post_import_workflow_count -gt 0 ]]; then
            log INFO "No new workflows imported; instance currently has $post_import_workflow_count workflow(s)."
        else
            log INFO "No workflows found after import."
        fi
    fi
    
    log HEADER "Restore Summary"
    log SUCCESS "✅ Restore completed successfully!"
    
    return 0
}