#!/usr/bin/env bash
# =========================================================
# lib/restore.sh - Restore operations for n8n-manager
# =========================================================
# All restore-related functions: restore process, rollback

# Source required modules
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

RESTORE_DUPLICATE_SKIPPED_COUNT=0
RESTORE_DUPLICATE_OVERWRITTEN_COUNT=0
RESTORE_DUPLICATE_ARCHIVED_COUNT=0

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
    
    if [[ ! -f "$pre_import_snapshot" || ! -f "$post_import_snapshot" || ! -f "$manifest_path" ]]; then
        log ERROR "Missing required files for workflow ID reconciliation"
        return 1
    fi
    
    local reconciliation_tmp
    reconciliation_tmp=$(mktemp -t n8n-reconciled-manifest-XXXXXXXX.json)

    local jq_error_log
    jq_error_log=$(mktemp -t n8n-reconcile-jq-XXXXXXXX.log)

    if ! jq -n \
        --slurpfile pre "$pre_import_snapshot" \
        --slurpfile post "$post_import_snapshot" \
        --slurpfile manifest "$manifest_path" '
            def arr(x): if (x | type) == "array" then x else [] end;
            def norm(v): (v // "" | ascii_downcase);
            def idx_by_id(arr):
                arr
                | reduce .[] as $item ({};
                    ($item.id // "" | tostring) as $id |
                    if ($id | length) > 0 then .[$id] = $item else . end
                );
            def idx_by_meta(arr):
                arr
                | map({meta: norm(.meta.instanceId // .meta.instanceID // ""), value: .})
                | group_by(.meta)
                | reduce .[] as $bucket ({};
                    ($bucket[0].meta) as $meta |
                    if ($meta | length) > 0 then .[$meta] = ($bucket | map(.value)) else . end
                );
            def idx_new_by_name(arr):
                arr
                | group_by(norm(.name // ""))
                | reduce .[] as $bucket ({};
                    norm($bucket[0].name // "") as $key |
                    if ($key | length) > 0 then .[$key] = $bucket else . end
                );
            def has_post_id($postById; $id): ($id | length) > 0 and ($postById[$id] // null) != null;
            def set_resolution($id; $strategy; $note):
                if ($id | length) > 0 then
                    ($id | tostring) as $resolvedId |
                    .id = $resolvedId
                    | .actualImportedId = $resolvedId
                    | .idReconciled = true
                    | .idResolutionStrategy = $strategy
                    | (if ($note | length) > 0 then .idResolutionNote = $note else del(.idResolutionNote) end)
                    | del(.idReconciliationWarning)
                else
                    .
                end;
            def add_warning($warning):
                if ($warning | length) == 0 then .
                else
                    .idReconciliationWarning = (
                        if has("idReconciliationWarning") then
                            .idReconciliationWarning + "; " + $warning
                        else
                            $warning
                        end)
                end;
            def mark_unresolved:
                .idReconciled = false
                | .idResolutionStrategy = "unresolved"
                | .actualImportedId = null
                | .;

            arr($pre[0]) as $preWorkflows |
            arr($post[0]) as $postWorkflows |
            arr($manifest[0]) as $manifestEntries |
            idx_by_id($preWorkflows) as $preById |
            idx_by_id($postWorkflows) as $postById |
            idx_by_meta($postWorkflows) as $postByMeta |
            (
                $postWorkflows
                | map(select((.id // "" | tostring) as $id | ($preById[$id] // null) == null))
            ) as $newWorkflows |
            idx_new_by_name($newWorkflows) as $newByName |
            $manifestEntries
            | map(
                . as $entry |
                ($entry.id // "" | tostring) as $manifestId |
                ($entry.existingWorkflowId // "" | tostring) as $existingId |
                ($entry.originalWorkflowId // "" | tostring) as $originalId |
                norm($entry.metaInstanceId // "") as $metaIdNorm |
                norm($entry.name // "") as $nameLower |
                ($entry.duplicateAction // "") as $duplicateAction |
                ($entry.storagePath // "") as $storagePath |

                ($entry
                 | mark_unresolved
                 | del(.idReconciliationWarning)
                 | del(.idResolutionNote)
                ) as $base |

                (if has_post_id($postById; $manifestId) then
                    $base
                    | set_resolution($manifestId; "manifest-id"; "")
                elif has_post_id($postById; $existingId) then
                    $base
                    | set_resolution($existingId; "existing-workflow-id"; "")
                elif has_post_id($postById; $originalId) then
                    $base
                    | set_resolution($originalId; "original-workflow-id"; "")
                elif ($metaIdNorm | length) > 0 and ($postByMeta[$metaIdNorm] // []) | length == 1 then
                    ($postByMeta[$metaIdNorm][0].id // "" | tostring) as $resolvedId |
                    $base
                    | set_resolution($resolvedId; "meta-instance"; "")
                elif ($metaIdNorm | length) > 0 and ($postByMeta[$metaIdNorm] // []) | length > 1 then
                    $base
                    | add_warning("Multiple workflows share instanceId \($entry.metaInstanceId // "")")
                elif ($duplicateAction | ascii_downcase) == "skip" then
                    $base
                    | add_warning("Workflow import skipped per duplicate strategy; ID remains unchanged")
                elif ($nameLower | length) > 0 and ($newByName[$nameLower] // []) | length == 1 then
                    ($newByName[$nameLower][0].id // "" | tostring) as $resolvedId |
                    $base
                    | set_resolution($resolvedId; "new-workflow-name"; "")
                elif ($nameLower | length) > 0 and ($newByName[$nameLower] // []) | length > 1 then
                    $base
                    | add_warning("Multiple newly imported workflows share the name \($entry.name // "")")
                else
                    $base
                    | add_warning("Unable to locate imported workflow in post-import snapshot")
                end)
            )
        ' > "$reconciliation_tmp" 2>"$jq_error_log"; then
        log ERROR "Failed to reconcile workflow IDs in manifest"
        if [[ -s "$jq_error_log" ]]; then
            local jq_error_msg
            jq_error_msg=$(head -n 20 "$jq_error_log")
            log DEBUG "jq reconciliation stderr: $jq_error_msg"
        fi
        rm -f "$reconciliation_tmp"
        rm -f "$jq_error_log"
        return 1
    fi

    rm -f "$jq_error_log"

    mv "$reconciliation_tmp" "$output_path"

    local reconciled_count
    reconciled_count=$(jq '[.[] | select(.idReconciled == true)] | length' "$output_path" 2>/dev/null || echo "0")
    local warning_count
    warning_count=$(jq '[.[] | select(.idReconciled != true)] | length' "$output_path" 2>/dev/null || echo "0")

    if (( reconciled_count > 0 )); then
        log SUCCESS "Reconciled $reconciled_count workflow ID(s) using post-import snapshot"
    fi

    if (( warning_count > 0 )); then
        log WARN "$warning_count workflow(s) remain unresolved after ID reconciliation"
        if [[ "$verbose" == "true" ]]; then
            while IFS= read -r warning_entry; do
                local name
                local warning
                name=$(printf '%s' "$warning_entry" | jq -r '.name // "Workflow"' 2>/dev/null)
                warning=$(printf '%s' "$warning_entry" | jq -r '.idReconciliationWarning // ""' 2>/dev/null)
                if [[ -n "$warning" ]]; then
                    log DEBUG "Reconciliation warning for '$name': $warning"
                fi
            done < <(jq -c '.[] | select(.idReconciled != true)' "$output_path")
        fi
    fi

    return 0
}

summarize_manifest_assignment_status() {
    local manifest_path="$1"
    local summary_label="$2"

    if [[ -z "$manifest_path" || ! -f "$manifest_path" ]]; then
        return 0
    fi

    local summary_json
    summary_json=$(jq -n --slurpfile manifest "$manifest_path" '
        def arr(x): if (x | type) == "array" then x else [] end;
        ($manifest[0] | arr) as $entries
        | {
            total: ($entries | length),
            resolved: ($entries | map(select(.idReconciled == true)) | length),
            unresolved: ($entries | map(select(.idReconciled != true)) | length),
            strategies: (
                $entries
                | map(select((.idResolutionStrategy // "") != ""))
                | group_by(.idResolutionStrategy // "unknown")
                | map({strategy: (.[0].idResolutionStrategy // "unknown"), count: length})
            ),
            warnings: (
                $entries
                | map(select((.idReconciled != true) and ((.idReconciliationWarning // "") != ""))
                      | {name: (.name // ""), warning: .idReconciliationWarning})
            )
        }
    ' 2>/dev/null)

    if [[ -z "$summary_json" ]]; then
        return 0
    fi

    local total resolved unresolved
    total=$(printf '%s' "$summary_json" | jq -r '.total' 2>/dev/null)
    resolved=$(printf '%s' "$summary_json" | jq -r '.resolved' 2>/dev/null)
    unresolved=$(printf '%s' "$summary_json" | jq -r '.unresolved' 2>/dev/null)

    if [[ -z "$total" || "$total" == "null" ]]; then
        return 0
    fi

    local label_suffix=""
    if [[ -n "$summary_label" ]]; then
        label_suffix=" ($summary_label)"
    fi

    log INFO "Workflow manifest reconciliation summary${label_suffix}: ${resolved}/${total} resolved, ${unresolved} unresolved."

    if [[ "$verbose" == "true" ]]; then
        while IFS=$'\t' read -r strategy count; do
            [[ -z "$strategy" ]] && continue
            log DEBUG "  • Strategy '${strategy}': ${count} workflow(s)"
        done < <(printf '%s' "$summary_json" | jq -r '.strategies[]? | (.strategy // "unknown") + "\t" + ((.count // 0)|tostring)' 2>/dev/null)

        local warning_index=0
        while IFS= read -r warning_entry; do
            [[ -z "$warning_entry" ]] && continue
            local warn_name warn_text
            warn_name=$(printf '%s' "$warning_entry" | jq -r '.name // "Workflow"' 2>/dev/null)
            warn_text=$(printf '%s' "$warning_entry" | jq -r '.warning // empty' 2>/dev/null)
            if [[ -n "$warn_text" ]]; then
                log DEBUG "  ⚠️  ${warn_name}: ${warn_text}"
            fi
            warning_index=$((warning_index + 1))
            if (( warning_index >= 5 )); then
                break
            fi
        done < <(printf '%s' "$summary_json" | jq -c '.warnings[]?' 2>/dev/null)
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

    local normalized
    normalized="${raw_input//\\/\/}"
    normalized=$(printf '%s' "$normalized" | sed 's/[[:space:]]\+/ /g; s/^ *//; s/ *$//')
    normalized=$(printf '%s' "$normalized" | sed 's:/\+:/:g')
    normalized="${normalized#/}"
    normalized="${normalized%/}"
    if [[ -z "$normalized" ]]; then
        printf ''
        return 0
    fi
    normalized=$(printf '%s' "$normalized" | tr '[:upper:]' '[:lower:]')
    printf '%s' "$normalized"
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

    local repo_prefix=""
    repo_prefix="$(effective_repo_prefix)"
    local repo_prefix_root_slug=""
    local repo_prefix_root_display=""
    if [[ -n "$repo_prefix" ]]; then
        local repo_prefix_basename="${repo_prefix##*/}"
        repo_prefix_root_slug="$(sanitize_slug "$repo_prefix_basename")"
        if [[ -n "$repo_prefix_root_slug" ]]; then
            repo_prefix_root_display="$(unslug_to_title "$repo_prefix_root_slug")"
        else
            repo_prefix_root_slug=""
            repo_prefix_root_display=""
        fi
    fi

    local manifest_indexed=false
    declare -A manifest_storage_entries=()
    declare -A manifest_storage_scores=()
    declare -A manifest_storage_updates=()
    declare -A manifest_relpath_entries=()
    declare -A manifest_relpath_scores=()
    declare -A manifest_relpath_updates=()
    declare -A manifest_reldir_entries=()
    declare -A manifest_reldir_scores=()
    declare -A manifest_reldir_updates=()
    declare -A manifest_filename_entries=()
    declare -A manifest_filename_scores=()
    declare -A manifest_filename_updates=()
    declare -A manifest_canonical_entries=()
    declare -A manifest_canonical_scores=()
    declare -A manifest_canonical_updates=()

    if [[ -n "$manifest_path" && -f "$manifest_path" ]]; then
        local manifest_index_file
        manifest_index_file=$(mktemp -t n8n-manifest-index-XXXXXXXX.ndjson)
        local manifest_index_err
        manifest_index_err=$(mktemp -t n8n-manifest-index-err-XXXXXXXX.log)

        local manifest_index_jq
        manifest_index_jq=$(cat <<'JQ'
            def norm(v):
                (v // "")
                | gsub("\\\\"; "/")
                | gsub("[[:space:]]+"; " ")
                | ascii_downcase
                | gsub("^ "; "")
                | gsub(" $"; "")
                | gsub("/+"; "/")
                | gsub("^/"; "")
                | gsub("/$"; "");

            def dir_norm(v):
                (v // "")
                | gsub("\\\\"; "/")
                | gsub("^/+"; "")
                | gsub("/+"; "/")
                | gsub("/$"; "")
                | split("/") as $parts
                | if ($parts | length) <= 1 then "" else ($parts[0:-1] | join("/")) end
                | gsub("[[:space:]]+"; " ")
                | ascii_downcase
                | gsub("^ "; "")
                | gsub(" $"; "")
                | gsub("^/+"; "")
                | gsub("/$"; "");

            def canonical(storage; filename):
                if (storage // "" | length) > 0 and (filename // "" | length) > 0 then
                    norm((storage // "") + "/" + (filename // ""))
                elif (filename // "" | length) > 0 then
                    norm(filename)
                else "" end;

            ($manifest[0] // [])
            | map(
                . + {
                    _normalizedStorage: norm(.storagePath),
                    _normalizedRelative: norm(.relativePath),
                    _normalizedRelativeDir: dir_norm(.relativePath),
                    _normalizedFilename: norm(.filename),
                    _normalizedCanonical: canonical(.storagePath; .filename),
                    _score: (
                        if (.actualImportedId // "" | length) > 0 then 400
                        elif (.id // "" | length) > 0 then 300
                        elif (.existingWorkflowId // "" | length) > 0 then 200
                        elif (.originalWorkflowId // "" | length) > 0 then 100
                        else 0 end
                    ),
                    _updatedAt: (.updatedAt // .metaUpdatedAt // .importedAt // "")
                }
            )
            | .[]
JQ
        )

        if jq -n --slurpfile manifest "$manifest_path" "$manifest_index_jq" > "$manifest_index_file" 2>"$manifest_index_err"; then
            while IFS= read -r manifest_line; do
                [[ -z "$manifest_line" ]] && continue

                local entry_score
                entry_score=$(printf '%s' "$manifest_line" | jq -r '._score // 0' 2>/dev/null || printf '0')
                local entry_updated
                entry_updated=$(printf '%s' "$manifest_line" | jq -r '._updatedAt // empty' 2>/dev/null)
                local storage_key
                storage_key=$(printf '%s' "$manifest_line" | jq -r '._normalizedStorage // empty' 2>/dev/null)
                local relative_key
                relative_key=$(printf '%s' "$manifest_line" | jq -r '._normalizedRelative // empty' 2>/dev/null)
                local relative_dir_key
                relative_dir_key=$(printf '%s' "$manifest_line" | jq -r '._normalizedRelativeDir // empty' 2>/dev/null)
                local filename_key
                filename_key=$(printf '%s' "$manifest_line" | jq -r '._normalizedFilename // empty' 2>/dev/null)
                local canonical_key
                canonical_key=$(printf '%s' "$manifest_line" | jq -r '._normalizedCanonical // empty' 2>/dev/null)

                local payload
                payload=$(printf '%s' "$manifest_line" | jq -c 'del(._normalizedStorage, ._normalizedRelative, ._normalizedRelativeDir, ._normalizedFilename, ._normalizedCanonical, ._score, ._updatedAt)' 2>/dev/null)
                if [[ -z "$payload" ]]; then
                    payload="$manifest_line"
                fi

                assign_manifest_lookup_entry manifest_storage_entries manifest_storage_scores manifest_storage_updates "$storage_key" "$entry_score" "$entry_updated" "$payload"
                assign_manifest_lookup_entry manifest_relpath_entries manifest_relpath_scores manifest_relpath_updates "$relative_key" "$entry_score" "$entry_updated" "$payload"
                assign_manifest_lookup_entry manifest_reldir_entries manifest_reldir_scores manifest_reldir_updates "$relative_dir_key" "$entry_score" "$entry_updated" "$payload"
                assign_manifest_lookup_entry manifest_filename_entries manifest_filename_scores manifest_filename_updates "$filename_key" "$entry_score" "$entry_updated" "$payload"
                assign_manifest_lookup_entry manifest_canonical_entries manifest_canonical_scores manifest_canonical_updates "$canonical_key" "$entry_score" "$entry_updated" "$payload"

                manifest_indexed=true
            done < "$manifest_index_file"
        else
            log WARN "Unable to index staged workflow manifest for folder mapping."
            if [[ -s "$manifest_index_err" && "$verbose" == "true" ]]; then
                local manifest_index_preview
                manifest_index_preview=$(head -n 10 "$manifest_index_err" 2>/dev/null)
                if [[ -n "$manifest_index_preview" ]]; then
                    log DEBUG "Manifest index jq error: $manifest_index_preview"
                fi
            fi
        fi

        rm -f "$manifest_index_file" "$manifest_index_err"
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

        if $manifest_indexed; then
            local storage_norm
            storage_norm=$(normalize_manifest_lookup_key "$storage_path")
            local rel_file_norm
            rel_file_norm=$(normalize_manifest_lookup_key "$canonical_relative_path")
            local rel_dir_norm
            rel_dir_norm=$(normalize_manifest_lookup_key "$relative_dir_without_prefix")
            local filename_norm
            filename_norm=$(normalize_manifest_lookup_key "$filename")
            local canonical_norm
            canonical_norm=$(normalize_manifest_lookup_key "${storage_path}/${filename}")

            if [[ -n "$storage_norm" && -n "${manifest_storage_entries[$storage_norm]+set}" ]]; then
                manifest_entry="${manifest_storage_entries[$storage_norm]}"
                manifest_entry_source="storagePath"
            fi
            if [[ -z "$manifest_entry" && -n "$rel_file_norm" && -n "${manifest_relpath_entries[$rel_file_norm]+set}" ]]; then
                manifest_entry="${manifest_relpath_entries[$rel_file_norm]}"
                manifest_entry_source="relativePath"
            fi
            if [[ -z "$manifest_entry" && -n "$canonical_norm" && -n "${manifest_canonical_entries[$canonical_norm]+set}" ]]; then
                manifest_entry="${manifest_canonical_entries[$canonical_norm]}"
                manifest_entry_source="canonical"
            fi
            if [[ -z "$manifest_entry" && -n "$rel_dir_norm" && -n "${manifest_reldir_entries[$rel_dir_norm]+set}" ]]; then
                manifest_entry="${manifest_reldir_entries[$rel_dir_norm]}"
                manifest_entry_source="relativeDir"
            fi
            if [[ -z "$manifest_entry" && -n "$filename_norm" && -n "${manifest_filename_entries[$filename_norm]+set}" ]]; then
                manifest_entry="${manifest_filename_entries[$filename_norm]}"
                manifest_entry_source="filename"
            fi
        fi

        if [[ -n "$manifest_entry" ]]; then
            manifest_existing_id=$(printf '%s' "$manifest_entry" | jq -r '.existingWorkflowId // empty' 2>/dev/null)
            manifest_original_id=$(printf '%s' "$manifest_entry" | jq -r '.originalWorkflowId // empty' 2>/dev/null)
            manifest_actual_id=$(printf '%s' "$manifest_entry" | jq -r '.actualImportedId // empty' 2>/dev/null)
            manifest_strategy=$(printf '%s' "$manifest_entry" | jq -r '.idResolutionStrategy // empty' 2>/dev/null)
            manifest_warning=$(printf '%s' "$manifest_entry" | jq -r '.idReconciliationWarning // empty' 2>/dev/null)
            manifest_note=$(printf '%s' "$manifest_entry" | jq -r '.idResolutionNote // empty' 2>/dev/null)
        fi

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
            workflow_id=$(jq -r '.id // empty' "$workflow_file" 2>/dev/null)
            if [[ -n "$workflow_id" && "$workflow_id" != "null" ]]; then
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
        workflow_name=$(jq -r '.name // empty' "$workflow_file" 2>/dev/null)
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

        local -a raw_segments=()
        if [[ -n "$relative_dir_without_prefix" ]]; then
            IFS='/' read -r -a raw_segments <<< "$relative_dir_without_prefix"
        fi

        local configured_project_name="${project_name:-}"
        if [[ -z "$configured_project_name" || "$configured_project_name" == "null" ]]; then
            configured_project_name="Personal"
        fi

        local configured_project_slug
        configured_project_slug=$(sanitize_slug "$configured_project_name")
        if [[ -z "$configured_project_slug" ]]; then
            configured_project_slug="personal"
        fi

        local project_slug="$configured_project_slug"
        local project_display_name="$(unslug_to_title "$project_slug")"
        local folder_start_index=0

        if ((${#raw_segments[@]} > 0)); then
            local first_raw="${raw_segments[0]}"
            local first_trimmed="${first_raw#/}"
            first_trimmed="${first_trimmed%/}"
            local first_lower
            first_lower=$(printf '%s' "$first_trimmed" | tr '[:upper:]' '[:lower:]')

            if [[ "$first_lower" == "projects" && ${#raw_segments[@]} -ge 2 ]]; then
                local project_raw="${raw_segments[1]}"
                local derived_slug
                derived_slug=$(sanitize_slug "$project_raw")
                if [[ -z "$derived_slug" ]]; then
                    derived_slug=$(sanitize_slug "$(unslug_to_title "$project_raw")")
                fi
                if [[ -n "$derived_slug" ]]; then
                    project_slug="$derived_slug"
                    project_display_name=$(unslug_to_title "$project_slug")
                    folder_start_index=2
                fi
            elif [[ "$first_lower" == "project" && ${#raw_segments[@]} -ge 2 ]]; then
                local project_raw="${raw_segments[1]}"
                local derived_slug
                derived_slug=$(sanitize_slug "$project_raw")
                if [[ -z "$derived_slug" ]]; then
                    derived_slug=$(sanitize_slug "$(unslug_to_title "$project_raw")")
                fi
                if [[ -n "$derived_slug" ]]; then
                    project_slug="$derived_slug"
                    project_display_name=$(unslug_to_title "$project_slug")
                    folder_start_index=2
                fi
            elif [[ "$first_lower" == "personal" ]]; then
                folder_start_index=1
                project_slug="personal"
                project_display_name="Personal"
            elif [[ "$first_trimmed" =~ ^@?[Pp]roject[:=_-](.+)$ ]]; then
                local directive="${BASH_REMATCH[1]}"
                local directive_slug
                directive_slug=$(sanitize_slug "$directive")
                if [[ -n "$directive_slug" ]]; then
                    project_slug="$directive_slug"
                    project_display_name=$(unslug_to_title "$directive_slug")
                    folder_start_index=1
                fi
            fi
        fi

        local -a folder_slugs=()
        local -a folder_displays=()
        if ((${#raw_segments[@]} > folder_start_index)); then
            local idx
            for ((idx=folder_start_index; idx<${#raw_segments[@]}; idx++)); do
                local segment_raw="${raw_segments[$idx]}"
                segment_raw="${segment_raw#/}"
                segment_raw="${segment_raw%/}"
                if [[ -z "$segment_raw" ]]; then
                    continue
                fi
                local segment_slug
                segment_slug=$(sanitize_slug "$segment_raw")
                if [[ -z "$segment_slug" ]]; then
                    segment_slug=$(sanitize_slug "$(unslug_to_title "$segment_raw")")
                fi
                if [[ -z "$segment_slug" ]]; then
                    segment_slug="folder"
                fi
                local segment_display
                segment_display=$(unslug_to_title "$segment_slug")
                folder_slugs+=("$segment_slug")
                folder_displays+=("$segment_display")
            done
        fi

        if [[ -n "$repo_prefix_root_slug" ]]; then
            local needs_prefix="true"
            if ((${#folder_slugs[@]} > 0)); then
                if [[ "${folder_slugs[0]}" == "$repo_prefix_root_slug" ]]; then
                    needs_prefix="false"
                fi
            fi
            if [[ "$needs_prefix" == "true" ]]; then
                folder_slugs=("$repo_prefix_root_slug" "${folder_slugs[@]}")
                folder_displays=("${repo_prefix_root_display:-$(unslug_to_title "$repo_prefix_root_slug")}" "${folder_displays[@]}")
            fi
        fi

    local relative_path="$canonical_relative_path"

        local display_path="$project_display_name"
        if ((${#folder_displays[@]} > 0)); then
            display_path+="/$(IFS=/; printf '%s' "${folder_displays[*]}")"
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
            --arg projectSlug "$project_slug" \
            --arg projectName "$project_display_name" \
            --arg manifestExisting "$manifest_existing_id" \
            --arg manifestOriginal "$manifest_original_id" \
            --arg manifestActual "$manifest_actual_id" \
            --arg manifestStrategy "$manifest_strategy" \
            --arg manifestWarning "$manifest_warning" \
            --arg manifestNote "$manifest_note" \
            --slurpfile folders "$folder_array_file" \
            '{
                id: ($id | select(. != "")),
                manifestActualWorkflowId: ($manifestActual | select(. != "")),
                manifestExistingWorkflowId: ($manifestExisting | select(. != "")),
                manifestOriginalWorkflowId: ($manifestOriginal | select(. != "")),
                manifestResolutionStrategy: ($manifestStrategy | select(. != "")),
                manifestResolutionWarning: ($manifestWarning | select(. != "")),
                manifestResolutionNote: ($manifestNote | select(. != "")),
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
            }' 2>"$entry_err")
        local entry_status=$?

        if [[ $entry_status -ne 0 || -z "$entry_json" || "$entry_json" == "null" ]]; then
            if [[ -s "$entry_err" && "$verbose" == "true" ]]; then
                local entry_error_preview
                entry_error_preview=$(head -n 5 "$entry_err" 2>/dev/null)
                if [[ -n "$entry_error_preview" ]]; then
                    log DEBUG "jq error while building folder entry for '$workflow_name': $entry_error_preview"
                fi
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
        printf '%s\n' "$snapshot_path"
        return 0
    fi

    log INFO "Workflow snapshot unavailable; proceeding without pre-import existence checks."
    if [[ "$session_initialized" == "true" && "$keep_session_alive" != "true" ]]; then
        finalize_n8n_api_auth
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
                    updatedAt: (e.updatedAt // "")
                },
                storagePath: (e.relativePath // ""),
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

build_restore_archive_plan() {
    local manifest_path="$1"
    local mapping_path="$2"
    local duplicate_strategy="$3"
    local output_path="$4"

    if [[ -z "$output_path" ]]; then
        log ERROR "Archive plan output path not provided."
        return 1
    fi

    if [[ -z "$manifest_path" || ! -f "$manifest_path" ]]; then
        printf '[]' > "$output_path"
        return 0
    fi

    local strategy_lower
    strategy_lower=$(printf '%s' "$duplicate_strategy" | tr '[:upper:]' '[:lower:]')

    if [[ "$strategy_lower" == "replace" ]]; then
        printf '[]' > "$output_path"
        return 0
    fi

    if [[ "$strategy_lower" == "overwrite" && ( -z "$mapping_path" || ! -f "$mapping_path" ) ]]; then
        log WARN "Duplicate strategy 'overwrite' requires workflow mapping. Falling back to path duplicate replacements only."
    fi

    local jq_args=(-n --slurpfile manifest "$manifest_path" --arg strategy "$strategy_lower")
    if [[ -n "$mapping_path" && -f "$mapping_path" ]]; then
        jq_args+=(--slurpfile mapping "$mapping_path")
    else
        jq_args+=(--slurpfile mapping /dev/null)
    fi

    local jq_program='
        def norm(v):
            (v // "") | ascii_downcase;

        def unique_by_id(list):
            reduce list[] as $item ([];
                if ($item.id // "") == "" then .
                elif any(.[]; (.id // "") == ($item.id // "")) then .
                else . + [$item] end
            );

        def manifest_entries:
            ($manifest[0] // []);

        def mapping_entries:
            if ($mapping | length) > 0 then ($mapping[0].workflows // []) else [] end;

        def duplicates_from_manifest:
            manifest_entries
            | map(select((.existingWorkflowId // "") != ""))
            | map({
                id: .existingWorkflowId,
                name: (.name // ""),
                storagePath: (.existingStoragePath // .storagePath // ""),
                reason: (.duplicateMatchType // "path-duplicate")
            });

        def folder_sync_entries:
            manifest_entries as $entries
            | mapping_entries as $existing
            | ($entries | map(.storagePath // "") | map(norm(.)) | unique) as $paths
            | [ $paths[] as $path
                | $existing
                | map(select(norm(.relativePath) == $path))
                | .[]
                | {
                    id: (.id // ""),
                    name: (.name // ""),
                    storagePath: (.relativePath // ""),
                    reason: "folder-sync"
                }
              ];

        (duplicates_from_manifest) as $dupes
        | (if $strategy == "overwrite" then folder_sync_entries else [] end) as $sync
        | unique_by_id($dupes + $sync)
    '

    local jq_output
    if ! jq_output=$(jq "${jq_args[@]}" "$jq_program" 2>/dev/null); then
        log WARN "Unable to build archive plan from manifest; duplicate handling may be limited."
        printf '[]' > "$output_path"
        return 1
    fi

    printf '%s' "$jq_output" > "$output_path"
    return 0
}

execute_restore_archive_plan() {
    local plan_path="$1"
    local container_id="$2"
    local keep_session_alive="$3"
    local is_dry_run="${4:-false}"

    if [[ -z "$plan_path" || ! -f "$plan_path" ]]; then
        return 0
    fi

    local plan_count
    plan_count=$(jq 'length' "$plan_path" 2>/dev/null)
    if [[ -z "$plan_count" || "$plan_count" == "0" ]]; then
        return 0
    fi

    if [[ "$is_dry_run" == "true" ]]; then
        while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            local workflow_id
            workflow_id=$(printf '%s' "$entry" | jq -r '.id // empty' 2>/dev/null)
            local workflow_name
            workflow_name=$(printf '%s' "$entry" | jq -r '.name // empty' 2>/dev/null)
            local storage_path
            storage_path=$(printf '%s' "$entry" | jq -r '.storagePath // empty' 2>/dev/null)
            log DRYRUN "Would archive workflow ${workflow_id:-<unknown>}${workflow_name:+ ($workflow_name)} from path ${storage_path:-<unknown>}."
        done < <(jq -c '.[]' "$plan_path")
        return 0
    fi

    if [[ -z "$n8n_base_url" ]]; then
        log WARN "n8n base URL not configured; cannot archive existing workflows prior to import."
        return 0
    fi

    local api_active=false
    if ! prepare_n8n_api_auth "$container_id" ""; then
        log WARN "Unable to authenticate with n8n API; skipping archive of existing workflows."
        return 1
    fi
    api_active=true

    local archived=0
    local failed=0

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local workflow_id workflow_name storage_path reason
        workflow_id=$(printf '%s' "$entry" | jq -r '.id // empty' 2>/dev/null)
        workflow_name=$(printf '%s' "$entry" | jq -r '.name // empty' 2>/dev/null)
        storage_path=$(printf '%s' "$entry" | jq -r '.storagePath // empty' 2>/dev/null)
        reason=$(printf '%s' "$entry" | jq -r '.reason // empty' 2>/dev/null)

        if [[ -z "$workflow_id" ]]; then
            continue
        fi

        if n8n_api_archive_workflow "$workflow_id"; then
            archived=$((archived + 1))
            log INFO "Archived workflow ${workflow_id}${workflow_name:+ ($workflow_name)} from path ${storage_path:-<unknown>} (reason: ${reason:-duplicate})."
        else
            failed=$((failed + 1))
            log WARN "Failed to archive workflow ${workflow_id}${workflow_name:+ ($workflow_name)} prior to import."
        fi
    done < <(jq -c '.[]' "$plan_path")

    if (( archived > 0 )); then
        RESTORE_DUPLICATE_ARCHIVED_COUNT=$((RESTORE_DUPLICATE_ARCHIVED_COUNT + archived))
        log INFO "Archived $archived existing workflow(s) prior to import."
    fi

    if (( failed > 0 )); then
        log WARN "Encountered errors while archiving $failed workflow(s); duplicates may persist."
    fi

    if $api_active && [[ "$keep_session_alive" != "true" ]]; then
        finalize_n8n_api_auth
    fi

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

    local repo_prefix_value
    repo_prefix_value="$(effective_repo_prefix)"
    local repo_prefix_root_slug=""
    local repo_prefix_root_display=""
    local repo_prefix_root_slug_lower=""
    if [[ -n "$repo_prefix_value" ]]; then
        local repo_prefix_basename="${repo_prefix_value##*/}"
        repo_prefix_root_slug="$(sanitize_slug "$repo_prefix_basename")"
        if [[ -n "$repo_prefix_root_slug" ]]; then
            repo_prefix_root_display="$(unslug_to_title "$repo_prefix_root_slug")"
            repo_prefix_root_slug_lower="$(printf '%s' "$repo_prefix_root_slug" | tr '[:upper:]' '[:lower:]')"
        else
            repo_prefix_root_slug=""
        fi
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
        if [[ "$verbose" == "true" ]]; then
            local projects_preview
            projects_preview=$(printf '%s' "$projects_json" | head -c 400 2>/dev/null)
            log DEBUG "Projects payload preview: ${projects_preview:-<empty>}"
        fi
        rm -f "$project_entries_file" "$project_entries_err"
        finalize_n8n_api_auth
        return 1
    fi
    rm -f "$project_entries_err"

    declare -A project_name_map=()
    declare -A project_slug_map=()
    declare -A project_id_map=()
    local default_project_id=""
    local personal_project_id=""

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
    done < "$project_entries_file"
    rm -f "$project_entries_file"

    if [[ -z "$default_project_id" ]]; then
        finalize_n8n_api_auth
        log ERROR "No projects available in n8n instance; cannot restore folder structure."
        return 1
    fi

    if [[ -n "$personal_project_id" ]]; then
        default_project_id="$personal_project_id"
        project_name_map["personal"]="$personal_project_id"
        project_slug_map["personal"]="$personal_project_id"
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
        if [[ "$verbose" == "true" ]]; then
            local folders_preview
            folders_preview=$(printf '%s' "$folders_json" | head -c 400 2>/dev/null)
            log DEBUG "Folders payload preview: ${folders_preview:-<empty>}"
        fi
        rm -f "$folder_entries_file" "$folder_entries_err"
        finalize_n8n_api_auth
        return 1
    fi
    rm -f "$folder_entries_err"

    declare -A folder_parent_lookup=()
    declare -A folder_project_lookup=()
    declare -A folder_slug_by_id=()
    declare -A folder_name_by_id=()
    declare -A folder_slug_lookup=()
    declare -A folder_name_lookup=()
    declare -A folder_duplicate_warned=()

    local folder_entry_count
    folder_entry_count=$(wc -l < "$folder_entries_file" 2>/dev/null | tr -d '[:space:]')
    log DEBUG "Prepared ${folder_entry_count:-0} folder entr(y/ies) from API payload."

    while IFS= read -r folder_entry; do
        local fid
        fid=$(printf '%s' "$folder_entry" | jq -r '.id // empty' 2>/dev/null)
        local fname
        fname=$(printf '%s' "$folder_entry" | jq -r '.name // empty' 2>/dev/null)
        local fproject
        fproject=$(printf '%s' "$folder_entry" | jq -r '.projectId // (.homeProject.id // .homeProjectId // empty)' 2>/dev/null)
        fproject=$(normalize_entry_identifier "$fproject")
        if [[ -z "$fid" || -z "$fproject" ]]; then
            if [[ -n "$fid" && "$verbose" == "true" ]]; then
                log DEBUG "Skipping folder '$fid' due to missing project reference in API payload."
            fi
            continue
        fi
        local parent
        parent=$(normalize_entry_identifier "$(printf '%s' "$folder_entry" | jq -r '.parentFolderId // (.parentFolder.id // .parentFolderId // empty)' 2>/dev/null)")
        local parent_key="${parent:-root}"
        local folder_slug
        folder_slug=$(sanitize_slug "$fname")
        folder_parent_lookup["$fid"]="$parent_key"
        folder_project_lookup["$fid"]="$fproject"
        folder_slug_by_id["$fid"]="$folder_slug"
        folder_name_by_id["$fid"]="$fname"

        local folder_slug_lower
        folder_slug_lower=$(printf '%s' "$folder_slug" | tr '[:upper:]' '[:lower:]')
        local folder_name_lower
        folder_name_lower=$(printf '%s' "$fname" | tr '[:upper:]' '[:lower:]')

        if [[ -n "$folder_slug_lower" ]]; then
            local slug_key="$fproject|${parent_key}|$folder_slug_lower"
            local existing_slug_id="${folder_slug_lookup[$slug_key]:-}"
            if [[ -n "$existing_slug_id" && "$existing_slug_id" != "$fid" ]]; then
                local warn_key="slug|$slug_key|$existing_slug_id"
                if [[ -z "${folder_duplicate_warned[$warn_key]+set}" ]]; then
                    log WARN "Multiple folders share slug '${folder_slug_lower:-<empty>}' under parent '${parent_key:-root}' in project '$fproject' (IDs: $existing_slug_id, $fid)."
                    folder_duplicate_warned[$warn_key]=1
                fi
            else
                folder_slug_lookup[$slug_key]="$fid"
            fi
        fi

        if [[ -n "$folder_name_lower" ]]; then
            local name_key="$fproject|${parent_key}|$folder_name_lower"
            local existing_name_id="${folder_name_lookup[$name_key]:-}"
            if [[ -n "$existing_name_id" && "$existing_name_id" != "$fid" ]]; then
                local warn_key="name|$name_key|$existing_name_id"
                if [[ -z "${folder_duplicate_warned[$warn_key]+set}" ]]; then
                    log WARN "Multiple folders share name '${folder_name_lower:-<empty>}' under parent '${parent_key:-root}' in project '$fproject' (IDs: $existing_name_id, $fid)."
                    folder_duplicate_warned[$warn_key]=1
                fi
            else
                folder_name_lookup[$name_key]="$fid"
            fi
        fi
    done < "$folder_entries_file"
    rm -f "$folder_entries_file"

    declare -A folder_path_lookup=()
    for fid in "${!folder_project_lookup[@]}"; do
        local project_ref="${folder_project_lookup[$fid]:-}"
        [[ -z "$project_ref" ]] && continue
        local current="$fid"
        local guard=0
        local -a path_segments=()
        while [[ -n "$current" && "$current" != "root" && $guard -lt 200 ]]; do
            local segment_slug="${folder_slug_by_id[$current]:-}"
            if [[ -z "$segment_slug" ]]; then
                segment_slug=$(sanitize_slug "${folder_name_by_id[$current]:-folder}")
            fi
            if [[ -z "$segment_slug" ]]; then
                segment_slug="folder"
            fi
            local segment_slug_lower
            segment_slug_lower=$(printf '%s' "$segment_slug" | tr '[:upper:]' '[:lower:]')
            path_segments=("$segment_slug_lower" "${path_segments[@]}")
            local parent_ref="${folder_parent_lookup[$current]:-root}"
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
        local existing_path_id="${folder_path_lookup[$path_key]:-}"
        if [[ -n "$existing_path_id" && "$existing_path_id" != "$fid" ]]; then
            local warn_key="path|$path_key|$existing_path_id"
            if [[ -z "${folder_duplicate_warned[$warn_key]+set}" ]]; then
                log WARN "Multiple folders resolve to slug path '$slug_path' in project '$project_ref' (IDs: $existing_path_id, $fid)."
                folder_duplicate_warned[$warn_key]=1
            fi
            continue
        fi
        folder_path_lookup[$path_key]="$fid"
    done

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
        if [[ "$verbose" == "true" ]]; then
            local workflows_preview
            workflows_preview=$(printf '%s' "$workflows_json" | head -c 400 2>/dev/null)
            log DEBUG "Workflows payload preview: ${workflows_preview:-<empty>}"
        fi
        rm -f "$workflow_entries_file" "$workflow_entries_err"
        finalize_n8n_api_auth
        return 1
    fi
    rm -f "$workflow_entries_err"

    declare -A workflow_version_lookup=()
    declare -A workflow_parent_lookup=()
    declare -A workflow_project_lookup=()
    declare -A workflow_name_lookup=()
    declare -A workflow_name_conflicts=()

    local workflow_entry_count
    workflow_entry_count=$(wc -l < "$workflow_entries_file" 2>/dev/null | tr -d '[:space:]')
    log DEBUG "Prepared ${workflow_entry_count:-0} workflow entr(y/ies) from API payload."

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
        workflow_version_lookup["$wid"]="$version_id"
        workflow_parent_lookup["$wid"]="$wparent"
        workflow_project_lookup["$wid"]="$wproject"

        local wname_lower
        wname_lower=$(printf '%s' "$workflow_entry" | jq -r '.name // empty' 2>/dev/null | tr '[:upper:]' '[:lower:]')
        if [[ -n "$wname_lower" && "$wname_lower" != "null" && -n "$wproject" ]]; then
            wname_lower=$(printf '%s' "$wname_lower" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
            if [[ -n "$wname_lower" ]]; then
                local name_key="$wproject|$wname_lower"
                if [[ -n "${workflow_name_lookup[$name_key]+set}" && "${workflow_name_lookup[$name_key]}" != "$wid" ]]; then
                    workflow_name_conflicts["$name_key"]=1
                else
                    workflow_name_lookup["$name_key"]="$wid"
                fi
            fi
        fi
    done < "$workflow_entries_file"
    rm -f "$workflow_entries_file"

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
    log DEBUG "Prepared ${entry_record_count:-0} folder workflow entr(y/ies) for processing."

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

        if [[ -n "$repo_prefix_root_slug_lower" && ${#folder_entries[@]} -ge 2 ]]; then
            local first_segment_json="${folder_entries[0]}"
            local first_segment_slug
            first_segment_slug=$(printf '%s' "$first_segment_json" | jq -r '.slug // empty' 2>/dev/null)
            local first_segment_name
            first_segment_name=$(printf '%s' "$first_segment_json" | jq -r '.name // empty' 2>/dev/null)
            if [[ -z "$first_segment_slug" || "$first_segment_slug" == "null" ]]; then
                first_segment_slug="$(sanitize_slug "$first_segment_name")"
            fi
            local first_segment_slug_lower=""
            if [[ -n "$first_segment_slug" && "$first_segment_slug" != "null" ]]; then
                first_segment_slug_lower="$(printf '%s' "$first_segment_slug" | tr '[:upper:]' '[:lower:]')"
            fi

            if [[ -n "$first_segment_slug_lower" && "$first_segment_slug_lower" == "$repo_prefix_root_slug_lower" ]]; then
                local second_segment_json="${folder_entries[1]}"
                local second_segment_slug
                second_segment_slug=$(printf '%s' "$second_segment_json" | jq -r '.slug // empty' 2>/dev/null)
                local second_segment_name
                second_segment_name=$(printf '%s' "$second_segment_json" | jq -r '.name // empty' 2>/dev/null)
                if [[ -z "$second_segment_slug" || "$second_segment_slug" == "null" ]]; then
                    second_segment_slug="$(sanitize_slug "$second_segment_name")"
                fi
                local second_segment_slug_lower=""
                if [[ -n "$second_segment_slug" && "$second_segment_slug" != "null" ]]; then
                    second_segment_slug_lower="$(printf '%s' "$second_segment_slug" | tr '[:upper:]' '[:lower:]')"
                fi
                local second_segment_name_lower=""
                if [[ -n "$second_segment_name" && "$second_segment_name" != "null" ]]; then
                    second_segment_name_lower="$(printf '%s' "$second_segment_name" | tr '[:upper:]' '[:lower:]')"
                fi

                local root_lookup_id=""
                if [[ -n "$second_segment_slug_lower" ]]; then
                    local root_slug_key="$target_project_id|root|$second_segment_slug_lower"
                    if [[ -n "${folder_slug_lookup["$root_slug_key"]+set}" ]]; then
                        root_lookup_id="${folder_slug_lookup["$root_slug_key"]}"
                    fi
                fi
                if [[ -z "$root_lookup_id" && -n "$second_segment_name_lower" ]]; then
                    local root_name_key="$target_project_id|root|$second_segment_name_lower"
                    if [[ -n "${folder_name_lookup["$root_name_key"]+set}" ]]; then
                        root_lookup_id="${folder_name_lookup["$root_name_key"]}"
                    fi
                fi

                if [[ -n "$root_lookup_id" ]]; then
                    folder_entries=("${folder_entries[@]:1}")
                    if [[ "$verbose" == "true" ]]; then
                        local skip_label="${repo_prefix_root_display:-$repo_prefix_root_slug}"
                        log DEBUG "Reusing existing root folder '${second_segment_name:-$second_segment_slug}' and skipping repo prefix '${skip_label}'."
                    fi
                fi
            fi
        fi

        local parent_folder_id=""
        local current_slug_path=""
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

            if [[ -z "$folder_slug_lower" ]]; then
                folder_slug_lower=$(printf '%s' "$(sanitize_slug "$folder_name")" | tr '[:upper:]' '[:lower:]')
            fi

            local candidate_path=""
            if [[ -n "$folder_slug_lower" ]]; then
                if [[ -z "$current_slug_path" ]]; then
                    candidate_path="$folder_slug_lower"
                else
                    candidate_path="$current_slug_path/$folder_slug_lower"
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
                        log DEBUG "Matched folder by slug lookup '${folder_slug_lower:-<empty>}' under parent '${parent_key:-root}' (ID: $existing_folder_id)."
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
                log DEBUG "Evaluating folder segment '${folder_name:-${folder_slug:-<unnamed>}}' (slug: ${folder_slug:-<none>}) targeting parent '${parent_key}' in project '${target_project_id}' (path: ${debug_path_display})"
            fi

            if [[ -z "$existing_folder_id" ]]; then
                local create_name="$folder_name"
                if [[ -z "$create_name" ]]; then
                    create_name=$(unslug_to_title "$folder_slug")
                fi
                if [[ "$verbose" == "true" ]]; then
                    log DEBUG "Creating folder '$create_name' (slug: ${folder_slug:-<none>}) under project '${target_project_id}' parent '${parent_folder_id:-root}'"
                fi
                local create_response
                if ! create_response=$(n8n_api_create_folder "$create_name" "$target_project_id" "$parent_folder_id"); then
                    log ERROR "Failed to create folder '$create_name' in project '${project_id_map[$target_project_id]:-Default}'"
                    folder_failure=true
                    break
                fi
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

    log INFO "Folder synchronization summary: ${project_created_count} project(s) created, ${folder_created_count} folder(s) created, ${folder_moved_count} folder(s) repositioned, ${workflow_assignment_count} workflow(s) reassigned."

    if ! $overall_success; then
        log WARN "Folder structure restoration completed with warnings (${moved_count}/${total_count} workflows updated)."
        return 1
    fi

    log SUCCESS "Folder structure restored for $moved_count workflow(s)."
    return 0
}

stage_directory_workflows_to_container() {
    local source_dir="$1"
    local container_id="$2"
    local container_target_dir="$3"
    local manifest_output="${4:-}"
    local existing_snapshot="${5:-}"
    local duplicate_strategy="${6:-replace}"
    local existing_mapping="${7:-}"

    duplicate_strategy=$(printf '%s' "$duplicate_strategy" | tr '[:upper:]' '[:lower:]')
    case "$duplicate_strategy" in
        overwrite|skip|replace) ;;
        *)
            log WARN "Unknown duplicate strategy '$duplicate_strategy'; defaulting to 'replace'."
            duplicate_strategy="replace"
            ;;
    esac

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

        local canonical_relative_path
        canonical_relative_path="$(strip_github_path_prefix "$relative_path")"
        canonical_relative_path="${canonical_relative_path#/}"
        canonical_relative_path="${canonical_relative_path%/}"

        local repo_entry_path
        repo_entry_path="$(compose_repo_storage_path "$canonical_relative_path")"
        repo_entry_path="${repo_entry_path#/}"
        repo_entry_path="${repo_entry_path%/}"

        local canonical_storage_path
        canonical_storage_path="$(compose_repo_storage_path "$(strip_github_path_prefix "$relative_dir")")"
        canonical_storage_path="${canonical_storage_path#/}"
        canonical_storage_path="${canonical_storage_path%/}"

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
        local staged_id staged_name staged_instance staged_description
        staged_id=$(jq -r '.id // empty' "$staged_path" 2>/dev/null || printf '')
        staged_name=$(jq -r '.name // empty' "$staged_path" 2>/dev/null || printf '')
        staged_instance=$(jq -r '.meta.instanceId // empty' "$staged_path" 2>/dev/null || printf '')
        staged_description=$(jq -r '.description // empty' "$staged_path" 2>/dev/null || printf '')
        local original_staged_id="$staged_id"
        local resolved_id_source=""
        local mapping_match_json=""

        if [[ -n "$existing_mapping" && -f "$existing_mapping" && -n "$staged_name" ]]; then
            mapping_match_json=$(lookup_workflow_in_mapping "$existing_mapping" "$canonical_storage_path" "$staged_name") || mapping_match_json=""
            if [[ "$mapping_match_json" == "null" ]]; then
                mapping_match_json=""
            fi
        fi

        local duplicate_match_json="" duplicate_action="import"
        local existing_storage_path=""
        local skip_workflow=false
        local existing_workflow_id=""

        if [[ -n "$mapping_match_json" ]]; then
            duplicate_match_json="$mapping_match_json"
            resolved_id_source=$(printf '%s' "$mapping_match_json" | jq -r '.matchType // empty' 2>/dev/null)
        fi

        # Check for existing workflows with same name/path
        if [[ -z "$duplicate_match_json" && -n "$existing_snapshot" && -f "$existing_snapshot" ]]; then
            duplicate_match_json=$(match_existing_workflow "$existing_snapshot" "$staged_id" "$staged_instance" "$staged_name" "$staged_description" "$repo_entry_path" "$existing_mapping") || duplicate_match_json=""
        elif [[ -z "$duplicate_match_json" && -n "$existing_mapping" && -f "$existing_mapping" ]]; then
            duplicate_match_json=$(match_existing_workflow "" "$staged_id" "$staged_instance" "$staged_name" "$staged_description" "$repo_entry_path" "$existing_mapping") || duplicate_match_json=""
        fi

        if [[ -n "$duplicate_match_json" ]]; then
            local match_type
            match_type=$(printf '%s' "$duplicate_match_json" | jq -r '.matchType // empty' 2>/dev/null)
            existing_workflow_id=$(printf '%s' "$duplicate_match_json" | jq -r '.workflow.id // empty' 2>/dev/null)
            existing_storage_path=$(printf '%s' "$duplicate_match_json" | jq -r '.storagePath // empty' 2>/dev/null)
            if [[ -z "$resolved_id_source" && -n "$match_type" ]]; then
                resolved_id_source="$match_type"
            fi
            
            if [[ "$duplicate_strategy" == "skip" ]]; then
                RESTORE_DUPLICATE_SKIPPED_COUNT=$((RESTORE_DUPLICATE_SKIPPED_COUNT + 1))
                duplicate_action="skip"
                skip_workflow=true
                log INFO "Skipping workflow '${staged_name:-$dest_filename}' due to existing match (${match_type:-unknown}) in path ${existing_storage_path:-${repo_entry_path:-${canonical_storage_path:-<unknown>}}}."
            elif [[ "$duplicate_strategy" == "overwrite" || "$duplicate_strategy" == "replace" ]]; then
                duplicate_action=$([[ "$duplicate_strategy" == "overwrite" ]] && printf '%s' "sync" || printf '%s' "replace")
                RESTORE_DUPLICATE_OVERWRITTEN_COUNT=$((RESTORE_DUPLICATE_OVERWRITTEN_COUNT + 1))
                if [[ "$duplicate_strategy" == "replace" ]]; then
                    log INFO "Queued workflow '${staged_name:-$dest_filename}' to replace existing ${existing_workflow_id:-<unknown>} in path ${existing_storage_path:-${repo_entry_path:-${canonical_storage_path:-<unknown>}}}."
                fi
            fi
        elif [[ -n "$existing_snapshot" && "$verbose" == "true" ]]; then
            log DEBUG "No duplicate match found for '${staged_name:-$dest_filename}' (name='${staged_name:-<none>}', instance='${staged_instance:-<none>}')."
        fi

        if [[ -n "$existing_workflow_id" ]]; then
            if [[ "$staged_id" != "$existing_workflow_id" ]]; then
                if jq --arg id "$existing_workflow_id" '.id = $id' "$staged_path" > "${staged_path}.tmp"; then
                    mv "${staged_path}.tmp" "$staged_path"
                    staged_id="$existing_workflow_id"
                    if [[ "$verbose" == "true" ]]; then
                        log DEBUG "Aligned workflow ID for '${staged_name:-$dest_filename}' to existing ID '$existing_workflow_id' (source: ${resolved_id_source:-resolved})."
                    fi
                else
                    rm -f "${staged_path}.tmp"
                    log WARN "Failed to apply resolved workflow ID '${existing_workflow_id}' for '${staged_name:-$dest_filename}'."
                fi
            fi
        fi

        if [[ "$skip_workflow" == "true" ]]; then
            rm -f "$staged_path"
            continue
        fi

        if [[ -z "$existing_workflow_id" && -n "$staged_id" ]]; then
            local id_is_known="false"
            if [[ -n "$existing_snapshot" && -f "$existing_snapshot" ]]; then
                if jq -e --arg id "$staged_id" '
                        (if type == "array" then . else [])
                        | map(select(((.id // empty) | tostring) == $id))
                        | length > 0
                    ' "$existing_snapshot" >/dev/null 2>&1; then
                    id_is_known="true"
                fi
            fi

            if [[ "$id_is_known" != "true" ]]; then
                if jq 'del(.id)' "$staged_path" > "${staged_path}.tmp"; then
                    mv "${staged_path}.tmp" "$staged_path"
                    if [[ "$verbose" == "true" ]]; then
                        log DEBUG "Cleared orphan workflow ID '${staged_id}' for '${staged_name:-$dest_filename}' (no matching workflow found)."
                    fi
                    staged_id=""
                else
                    rm -f "${staged_path}.tmp"
                    log WARN "Unable to clear orphan workflow ID '${staged_id}' for '${staged_name:-$dest_filename}'."
                fi
            fi
        fi

        if [[ "$verbose" == "true" && -n "$staged_id" ]]; then
            log DEBUG "Prepared workflow ID '${staged_id}' for n8n import (workflow: ${staged_name:-$dest_filename})"
        elif [[ "$verbose" == "true" ]]; then
            log DEBUG "Workflow '${staged_name:-$dest_filename}' will rely on n8n to assign a new ID during import"
        fi

        # Build manifest entry - Store workflow ID for post-import folder assignment
        if [[ -n "$manifest_entries_file" ]]; then
            local manifest_entry match_type_field=""
            
            if [[ -n "$duplicate_match_json" ]]; then
                match_type_field=$(printf '%s' "$duplicate_match_json" | jq -r '.matchType // empty' 2>/dev/null)
                if [[ -z "$existing_storage_path" ]]; then
                    existing_storage_path=$(printf '%s' "$duplicate_match_json" | jq -r '.storagePath // empty' 2>/dev/null)
                fi
            fi

            # Manifest entry contains:
            # - id: The workflow ID that will exist after import (from file or n8n-assigned)
            # - name: Backup identifier for name-based lookup if ID lookup fails
            # - storagePath: Determines folder structure
            # - existingWorkflowId: The ID that existed before (for tracking replacements)
            manifest_entry=$(jq -n \
                --arg filename "$dest_filename" \
                --arg id "$staged_id" \
                --arg name "$staged_name" \
                --arg description "$staged_description" \
                --arg instanceId "$staged_instance" \
                --arg matchType "$match_type_field" \
                --arg existingId "$existing_workflow_id" \
                --arg originalId "$original_staged_id" \
                --arg action "$duplicate_action" \
                --arg relative "$relative_path" \
                --arg storage "$canonical_storage_path" \
                                --arg existingStorage "$existing_storage_path" \
                                --arg idSource "$resolved_id_source" \
                '{
                  filename: $filename,
                  id: ($id | select(. != "")),
                  name: $name,
                  description: ($description | select(. != "")),
                  metaInstanceId: ($instanceId | select(. != "")),
                  duplicateMatchType: ($matchType | select(. != "")),
                  existingWorkflowId: ($existingId | select(. != "")),
                  originalWorkflowId: ($originalId | select(. != "")),
                  duplicateAction: $action,
                  relativePath: $relative,
                  storagePath: $storage,
                                    existingStoragePath: ($existingStorage | select(. != "")),
                                    idResolutionSource: ($idSource | select(. != ""))
                }')
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
                    if ! jq -s -c '.' "$manifest_entries_file" > "$manifest_output" 2>/dev/null; then
                        log WARN "Unable to generate staging manifest for workflows; duplicate detection may be limited."
                        printf '[]' > "$manifest_output" 2>/dev/null || true
                    fi
                fi
            elif [[ -n "$manifest_output" ]]; then
                printf '[]' > "$manifest_output" 2>/dev/null || true
            fi
            rm -f "$manifest_entries_file"
        fi
        rm -rf "$staging_dir"
        if (( RESTORE_DUPLICATE_SKIPPED_COUNT > 0 )); then
            log INFO "All candidate workflows skipped because they already exist in n8n."
            return 0
        fi
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
        if [[ -s "$manifest_entries_file" ]]; then
            if ! jq -s -c '.' "$manifest_entries_file" > "$manifest_output" 2>/dev/null; then
                log WARN "Unable to generate staging manifest for workflows; duplicate detection may be limited."
                printf '[]' > "$manifest_output"
            fi
        else
            printf '[]' > "$manifest_output"
        fi
        rm -f "$manifest_entries_file"
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
    local duplicate_strategy="${11:-replace}"
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
    duplicate_strategy=$(printf '%s' "$duplicate_strategy" | tr '[:upper:]' '[:lower:]')
    case "$duplicate_strategy" in
        overwrite|skip|replace) ;;
        *)
            log WARN "Unknown duplicate workflow strategy '$duplicate_strategy'; defaulting to 'replace'."
            duplicate_strategy="replace"
            ;;
    esac

    RESTORE_DUPLICATE_SKIPPED_COUNT=0
    RESTORE_DUPLICATE_OVERWRITTEN_COUNT=0

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
    local archive_plan_file=""
    local staged_manifest_copy=""
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
                        local snapshot_path=""
                        if snapshot_path=$(snapshot_existing_workflows "$container_id" "" "$keep_api_session_alive"); then
                            existing_workflow_snapshot="$snapshot_path"
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
                    if ! stage_directory_workflows_to_container "$stage_source_dir" "$container_id" "$container_import_workflows" "$staged_manifest_file" "$existing_workflow_snapshot" "$duplicate_strategy" "$existing_workflow_mapping"; then
                        rm -f "$staged_manifest_file"
                        log ERROR "Failed to copy workflow files into container."
                        copy_status="failed"
                    else
                        resolved_structured_dir="$stage_source_dir"
                        log SUCCESS "Workflow files prepared in container directory $container_import_workflows"

                        if [[ "$duplicate_strategy" == "overwrite" && -n "$staged_manifest_file" ]]; then
                            if [[ -n "$archive_plan_file" && -f "$archive_plan_file" ]]; then
                                rm -f "$archive_plan_file" || true
                                archive_plan_file=""
                            fi
                            archive_plan_file=$(mktemp -t n8n-archive-plan-XXXXXXXX.json)
                            if ! build_restore_archive_plan "$staged_manifest_file" "$existing_workflow_mapping" "$duplicate_strategy" "$archive_plan_file"; then
                                rm -f "$archive_plan_file"
                                archive_plan_file=""
                            else
                                execute_restore_archive_plan "$archive_plan_file" "$container_id" "$keep_api_session_alive" "$is_dry_run"
                                rm -f "$archive_plan_file"
                                archive_plan_file=""
                            fi
                        fi
                    fi
                fi
            fi
        else
            if [ "$is_dry_run" = "true" ]; then
                log DRYRUN "Would copy $repo_workflows to ${container_id}:${container_import_workflows}"
            else
                if [[ "$duplicate_strategy" != "skip" ]]; then
                    log WARN "Duplicate workflow strategy '$duplicate_strategy' is not applied when importing consolidated workflows.json exports."
                fi
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
                local snapshot_path=""
                if snapshot_path=$(snapshot_existing_workflows "$container_id" "" "$keep_api_session_alive"); then
                    existing_workflow_snapshot="$snapshot_path"
                    log DEBUG "Captured existing workflow snapshot from ${existing_workflow_snapshot_source:-unknown} source for duplicate detection."
                fi
            fi

            if [[ -n "$staged_manifest_file" && -f "$staged_manifest_file" ]]; then
                staged_manifest_copy=$(mktemp -t n8n-staged-workflows-XXXXXXXX.json)
                if ! cp "$staged_manifest_file" "$staged_manifest_copy"; then
                    log WARN "Unable to retain staged workflow manifest; duplicate detection may be limited."
                    rm -f "$staged_manifest_copy"
                    staged_manifest_copy=""
                fi
                rm -f "$staged_manifest_file"
                staged_manifest_file=""
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
                        if [[ -n "$existing_workflow_snapshot" && -f "$existing_workflow_snapshot" && -n "$staged_manifest_copy" && -f "$staged_manifest_copy" ]]; then
                            local post_import_snapshot=""
                            if post_import_snapshot=$(snapshot_existing_workflows "$container_id" "" "$keep_api_session_alive"); then
                                log DEBUG "Captured post-import workflow snapshot for ID reconciliation"
                                
                                # Update manifest with actual imported workflow IDs by comparing snapshots
                                local updated_manifest
                                updated_manifest=$(mktemp -t n8n-updated-manifest-XXXXXXXX.json)
                                if reconcile_imported_workflow_ids "$existing_workflow_snapshot" "$post_import_snapshot" "$staged_manifest_copy" "$updated_manifest"; then
                                    mv "$updated_manifest" "$staged_manifest_copy"
                                    log INFO "Reconciled manifest with actual imported workflow IDs from n8n"
                                    summarize_manifest_assignment_status "$staged_manifest_copy" "post-import"
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
    
    if [[ "$workflows_mode" != "0" && "$workflow_import_mode" == "directory" ]]; then
        if (( RESTORE_DUPLICATE_SKIPPED_COUNT > 0 )); then
            log WARN "Skipped $RESTORE_DUPLICATE_SKIPPED_COUNT workflow(s) already present in n8n (duplicate strategy: $duplicate_strategy)."
        fi
        if (( RESTORE_DUPLICATE_OVERWRITTEN_COUNT > 0 )); then
            log INFO "Overwrote $RESTORE_DUPLICATE_OVERWRITTEN_COUNT existing workflow(s) during import (duplicate strategy: $duplicate_strategy)."
        fi
        if (( RESTORE_DUPLICATE_ARCHIVED_COUNT > 0 )); then
            log INFO "Archived $RESTORE_DUPLICATE_ARCHIVED_COUNT workflow(s) ahead of import to keep project folders in sync."
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
            if ! apply_folder_structure_from_directory "$folder_source_dir" "$container_id" "$is_dry_run" "" "$staged_manifest_copy"; then
                log WARN "Folder structure restoration encountered issues; workflows may require manual reorganization."
            fi
        fi
    fi

    if [[ -n "$staged_manifest_copy" && -f "$staged_manifest_copy" ]]; then
        rm -f "$staged_manifest_copy"
    fi
    if [[ -n "$existing_workflow_snapshot" && -f "$existing_workflow_snapshot" ]]; then
        rm -f "$existing_workflow_snapshot"
    fi
    if [[ -n "$existing_workflow_mapping" && -f "$existing_workflow_mapping" ]]; then
        rm -f "$existing_workflow_mapping"
    fi

    if [[ "$keep_api_session_alive" == "true" && -n "${N8N_API_AUTH_MODE:-}" ]]; then
        finalize_n8n_api_auth
        keep_api_session_alive="false"
    fi

    # Clean up temporary files in container
    if [ "$is_dry_run" != "true" ]; then
        log INFO "Cleaning up temporary files in container..."
        if dockExecAsRoot "$container_id" "rm -rf $container_import_workflows $container_import_credentials 2>/dev/null || true" false; then
            log SUCCESS "Container cleanup complete."
        else
            log WARN "Unable to remove temporary workflow or credential files from container."
        fi
    else
        log DRYRUN "Would remove temporary workflow and credential files from container."
    fi
    
    # Clean up downloaded repository
    if [[ -n "$download_dir" ]]; then
        if rm -rf "$download_dir"; then
            log SUCCESS "Removed temporary download directory: $download_dir"
        else
            log WARN "Failed to remove temporary download directory: $download_dir"
        fi
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