#!/usr/bin/env bash
# =========================================================
# lib/n8n-api.sh - n8n REST API functions for n8n-manager
# =========================================================
# All functions for interacting with n8n's REST API to get
# Comprehensive API validation - tests all available authentication methods
# Build mapping of workflows to sanitized folder paths
sanitize_n8n_json_response() {
    local raw="${1-}"

    # Treat unset or empty payloads as an empty object to avoid jq errors
    if [[ -z "$raw" ]]; then
        printf '{}'
        return 0
    fi

    local sanitized="$raw"

    # Strip UTF-8 BOM if present and carriage returns that break jq parsing
    if [[ "${sanitized:0:1}" == $'\uFEFF' ]]; then
        sanitized="${sanitized:1}"
    fi
    sanitized="${sanitized//$'\r'/}"

    # Collapse payloads that are only whitespace or explicit null into empty object
    if [[ "$sanitized" =~ ^[[:space:]]*$ ]]; then
        printf '{}'
        return 0
    fi

    if [[ "$sanitized" == "null" ]]; then
        printf '{}'
        return 0
    fi

    printf '%s' "$sanitized"
}

normalize_identifier() {
    local value="${1-}"

    # Remove control characters and surrounding whitespace
    value="${value//$'\r'/}"
    value="${value//$'\n'/}"
    value="${value//$'\t'/}"

    value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//')"

    if [[ -z "$value" || "$value" == "null" ]]; then
        printf ''
        return 0
    fi

    # Retain only safe identifier characters (alphanumeric, underscore, hyphen)
    value="$(printf '%s' "$value" | tr -dc '[:alnum:]_-')"

    printf '%s' "$value"
}

sanitize_slug_value() {
    local raw="${1-}"

    raw="$(printf '%s' "$raw" | tr -d '\r\n\t')"
    raw="$(printf '%s' "$raw" | sed 's/^[[:space:]]\+//;s/[[:space:]]\+$//')"

    if [[ -z "$raw" ]]; then
        raw="folder"
    fi

    local lower
    lower="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
    lower="$(printf '%s' "$lower" | sed 's/[^[:alnum:]]\+/-/g')"
    lower="$(printf '%s' "$lower" | sed 's/-\{2,\}/-/g; s/^-*//; s/-*$//')"

    if (( ${#lower} > 96 )); then
        lower="${lower:0:96}"
        lower="$(printf '%s' "$lower" | sed 's/-\{2,\}/-/g; s/^-*//; s/-*$//')"
    fi

    if [[ -z "$lower" ]]; then
        lower="folder"
    fi

    printf '%s' "$lower"
}

build_folder_chain_json() {
    local start_id="${1:-}"
    declare -n __names_ref="$2"
    declare -n __slugs_ref="$3"
    declare -n __parent_ref="$4"
    local __chain_ref="$5"
    local __relative_ref="$6"
    local __display_ref="$7"

    local -a ancestry=()
    local current="$start_id"
    local guard=0

    while [[ -n "$current" ]]; do
        ancestry+=("$current")
        local next_parent="${__parent_ref[$current]:-}"
        if [[ -z "$next_parent" || "$next_parent" == "$current" ]]; then
            break
        fi

        current="$next_parent"
        guard=$((guard + 1))
        if (( guard > 128 )); then
            log WARN "Detected potential folder hierarchy loop while resolving chain for ${start_id:-unknown}"
            break
        fi
    done

    local -a chain_entries=()
    local -a relative_segments=()
    local -a display_segments=()

    for (( idx=${#ancestry[@]}-1; idx>=0; idx-- )); do
        local folder_id="${ancestry[idx]}"
        [[ -z "$folder_id" ]] && continue

        local folder_name="${__names_ref[$folder_id]:-Folder}"
        if [[ -z "$folder_name" || "$folder_name" == "null" ]]; then
            folder_name="Folder"
        fi

        local folder_slug="${__slugs_ref[$folder_id]:-}"
        if [[ -z "$folder_slug" || "$folder_slug" == "null" ]]; then
            folder_slug="$(sanitize_slug_value "$folder_name")"
        fi

        local entry_json
        if ! entry_json=$(jq -n -c --arg id "$folder_id" --arg name "$folder_name" --arg slug "$folder_slug" '{id:$id,name:$name,slug:$slug}'); then
            continue
        fi

        chain_entries+=("$entry_json")
        relative_segments+=("$folder_slug")
        display_segments+=("$folder_name")
    done

    local chain_json="[]"
    if ((${#chain_entries[@]} > 0)); then
        chain_json="$(printf '%s\n' "${chain_entries[@]}" | jq -s '.')"
    fi

    local relative_path=""
    if ((${#relative_segments[@]} > 0)); then
        local IFS='/'
        relative_path="${relative_segments[*]}"
    fi

    local display_path=""
    if ((${#display_segments[@]} > 0)); then
        local IFS='/'
        display_path="${display_segments[*]}"
    fi

    printf -v "$__chain_ref" '%s' "$chain_json"
    printf -v "$__relative_ref" '%s' "$relative_path"
    printf -v "$__display_ref" '%s' "$display_path"
}

get_workflow_folder_mapping() {
    local container_id="$1"
    local container_credentials_path="${2:-}"
    local result_ref="${3:-}"

    if [[ -z "${n8n_base_url:-}" ]]; then
        log ERROR "n8n API URL not configured. Please set N8N_BASE_URL"
        return 1
    fi

    if ! prepare_n8n_api_auth "$container_id" "$container_credentials_path"; then
        log ERROR "Unable to prepare n8n API authentication for workflow mapping"
        return 1
    fi

    local projects_response=""
    local workflows_response=""

    if ! projects_response=$(n8n_api_get_projects); then
        finalize_n8n_api_auth
        return 1
    fi

    if ! workflows_response=$(n8n_api_get_workflows); then
        finalize_n8n_api_auth
        return 1
    fi

    projects_response="$(printf '%s' "$projects_response" | tr -d '\r')"
    workflows_response="$(printf '%s' "$workflows_response" | tr -d '\r')"

    log DEBUG "get_workflow_folder_mapping verbose flag: ${verbose:-unset}"

    if [[ "$verbose" == "true" ]]; then
        local projects_preview
        local workflows_preview
        projects_preview="$(printf '%s' "$projects_response" | tr '\n' ' ' | head -c 200)"
        workflows_preview="$(printf '%s' "$workflows_response" | tr '\n' ' ' | head -c 200)"
        log DEBUG "Projects response preview: ${projects_preview}$( [ $(printf '%s' "$projects_response" | wc -c) -gt 200 ] && echo '…')"
        log DEBUG "Workflows response preview: ${workflows_preview}$( [ $(printf '%s' "$workflows_response" | wc -c) -gt 200 ] && echo '…')"
    fi

    if [[ "$verbose" == "true" ]]; then
        log DEBUG "Validating projects response JSON"
    fi

    if ! printf '%s' "$projects_response" | jq empty >/dev/null 2>&1; then
        local sample
        sample="$(printf '%s' "$projects_response" | tr '\n' ' ' | head -c 200)"
        log ERROR "Projects response is not valid JSON (sample: ${sample}...)"
        finalize_n8n_api_auth
        return 1
    fi

    if [[ "$verbose" == "true" ]]; then
        log DEBUG "Validating workflows response JSON"
    fi

    if ! printf '%s' "$workflows_response" | jq empty >/dev/null 2>&1; then
        local sample
        sample="$(printf '%s' "$workflows_response" | tr '\n' ' ' | head -c 200)"
        log ERROR "Workflows response is not valid JSON (sample: ${sample}...)"
        finalize_n8n_api_auth
        return 1
    fi

    local projects_tmp workflows_tmp
    projects_tmp=$(mktemp -t n8n-projects-XXXXXXXX.json)
    workflows_tmp=$(mktemp -t n8n-workflows-XXXXXXXX.json)
    printf '%s' "$projects_response" > "$projects_tmp"
    printf '%s' "$workflows_response" > "$workflows_tmp"

    trap 'rm -f "$projects_tmp" "$workflows_tmp"; trap - RETURN' RETURN

    declare -A project_name_by_id=()
    declare -A project_slug_by_id=()
    local default_project_id=""
    local personal_project_id=""

    local project_rows
    if ! project_rows=$(jq -r '
        (if type == "array" then . else (.data // []) end)
        | map([
            ((.id // "") | tostring),
            (.name // "Personal"),
            (.type // ""),
            ((.defaultSlug // "") | tostring)
          ] | @tsv)
        | .[]
    ' "$projects_tmp"); then
        log ERROR "Unable to parse projects while building workflow mapping"
        rm -f "$projects_tmp" "$workflows_tmp"
        trap - RETURN
        finalize_n8n_api_auth
        return 1
    fi

    if [[ -n "$project_rows" ]]; then
        while IFS=$'\t' read -r raw_id raw_name raw_type raw_slug; do
            local pid
            pid="$(normalize_identifier "$raw_id")"
            [[ -z "$pid" ]] && continue

            local pname="${raw_name:-Personal}"
            if [[ -z "$pname" || "$pname" == "null" ]]; then
                pname="Personal"
            fi
            local slug="${raw_slug:-}"
            if [[ -z "$slug" || "$slug" == "null" ]]; then
                slug="$(sanitize_slug_value "$pname")"
            fi

            project_name_by_id["$pid"]="$pname"
            project_slug_by_id["$pid"]="$slug"

            if [[ -z "$default_project_id" ]]; then
                default_project_id="$pid"
            fi
            if [[ "$raw_type" == "personal" ]]; then
                personal_project_id="$pid"
            fi
        done <<<"$project_rows"
    fi

    if [[ -z "$default_project_id" ]]; then
        default_project_id="personal-default"
        local default_name="Personal"
        local default_slug_local="personal"
        project_name_by_id["$default_project_id"]="$default_name"
        project_slug_by_id["$default_project_id"]="$default_slug_local"
    fi

    if [[ -n "$personal_project_id" ]]; then
        default_project_id="$personal_project_id"
    fi

    declare -A folder_name_by_id=()
    declare -A folder_slug_by_id=()
    declare -A folder_parent_by_id=()

    local folder_rows
    if ! folder_rows=$(jq -r '
        (if type == "array" then . else (.data // []) end)
        | map(select(.resource == "folder"))
        | map([
            ((.id // "") | tostring),
            (.name // "Folder"),
            ((.parentFolderId // (.parentFolder.id // "")) | tostring)
          ] | @tsv)
        | .[]
    ' "$workflows_tmp"); then
        log ERROR "Unable to parse folder entries while building workflow mapping"
        rm -f "$projects_tmp" "$workflows_tmp"
        trap - RETURN
        finalize_n8n_api_auth
        return 1
    fi

    if [[ -n "$folder_rows" ]]; then
        while IFS=$'\t' read -r raw_id raw_name raw_parent; do
            local fid
            fid="$(normalize_identifier "$raw_id")"
            if [[ -z "$fid" ]]; then
                continue
            fi

            local fname="${raw_name:-Folder}"
            if [[ -z "$fname" || "$fname" == "null" ]]; then
                fname="Folder"
            fi
            local fslug
            fslug="$(sanitize_slug_value "$fname")"
            local parent_id
            parent_id="$(normalize_identifier "$raw_parent")"

            folder_name_by_id["$fid"]="$fname"
            folder_slug_by_id["$fid"]="$fslug"
            folder_parent_by_id["$fid"]="$parent_id"
        done <<<"$folder_rows"
    fi

    local workflow_rows
    if ! workflow_rows=$(jq -r '
        (if type == "array" then . else (.data // []) end)
        | map(select(.resource != "folder"))
        | map([
                ((.id // "") | tostring),
                (.name // "Unnamed Workflow"),
                ((.homeProject.id // .homeProjectId // "") | tostring),
                ((.parentFolderId // (.parentFolder.id // "")) | tostring),
                (.updatedAt // "")
            ] | @tsv)
        | .[]
    ' "$workflows_tmp"); then
        log ERROR "Unable to parse workflows while building workflow mapping"
        rm -f "$projects_tmp" "$workflows_tmp"
        trap - RETURN
        finalize_n8n_api_auth
        return 1
    fi

    local -a workflow_entries=()
    if [[ -n "$workflow_rows" ]]; then
        while IFS=$'\t' read -r raw_id raw_name raw_project raw_parent raw_updated_at; do
            local wid
            wid="$(normalize_identifier "$raw_id")"
            if [[ -z "$wid" ]]; then
                continue
            fi

            local wname="${raw_name:-Unnamed Workflow}"
            if [[ -z "$wname" || "$wname" == "null" ]]; then
                wname="Unnamed Workflow"
            fi

            local project_id
            project_id="$(normalize_identifier "$raw_project")"
            if [[ -z "$project_id" ]]; then
                project_id="$default_project_id"
            fi
            local project_name="${project_name_by_id[$project_id]:-${project_name_by_id[$default_project_id]}}"
            local project_slug="${project_slug_by_id[$project_id]:-${project_slug_by_id[$default_project_id]}}"
            if [[ -z "$project_name" ]]; then
                project_name="${project_name_by_id[$default_project_id]}"
            fi
            if [[ -z "$project_slug" ]]; then
                project_slug="${project_slug_by_id[$default_project_id]}"
            fi

            if [[ -z "$project_name" || -z "$project_slug" ]]; then
                project_name="Personal"
                project_slug="$(sanitize_slug_value "$project_name")"
            fi

            local parent_id
            parent_id="$(normalize_identifier "$raw_parent")"
            local folder_chain_json="[]"
            local folder_relative=""
            local folder_display=""
            build_folder_chain_json "$parent_id" folder_name_by_id folder_slug_by_id folder_parent_by_id folder_chain_json folder_relative folder_display

            local relative_path="$project_slug"
            if [[ -n "$folder_relative" ]]; then
                relative_path+="/$folder_relative"
            fi

            local display_path="$project_name"
            if [[ -n "$folder_display" ]]; then
                display_path+="/$folder_display"
            fi

            local updated_at="${raw_updated_at:-}"

            local workflow_json
            if ! workflow_json=$(jq -n -c \
                --arg id "$wid" \
                --arg name "$wname" \
                --arg projectId "$project_id" \
                --arg projectName "$project_name" \
                --arg projectSlug "$project_slug" \
                --arg relative "$relative_path" \
                --arg display "$display_path" \
                --arg updatedAt "$updated_at" \
                --argjson folders "$folder_chain_json" '{
                    id: $id,
                    name: $name,
                    project: {
                        id: $projectId,
                        name: $projectName,
                        slug: $projectSlug
                    },
                    folders: $folders,
                    relativePath: $relative,
                    displayPath: $display,
                    updatedAt: (if ($updatedAt // "") == "" then null else $updatedAt end)
                }'); then
                log WARN "Failed to assemble workflow entry for ID $wid"
                continue
            fi

            workflow_entries+=("$workflow_json")
        done <<<"$workflow_rows"
    fi

    local mapping_json=""
    if ((${#workflow_entries[@]} > 0)); then
        if ! mapping_json=$(printf '%s\n' "${workflow_entries[@]}" | jq -s '{
            fetchedAt: (now | todateiso8601),
            workflows: .,
            workflowsById: (map({key: .id, value: .}) | from_entries)
        }'); then
            log ERROR "Failed to construct workflow mapping JSON"
            rm -f "$projects_tmp" "$workflows_tmp"
            trap - RETURN
            finalize_n8n_api_auth
            return 1
        fi
    else
        mapping_json=$(jq -n '{
            fetchedAt: (now | todateiso8601),
            workflows: [],
            workflowsById: {}
        }')
    fi

    rm -f "$projects_tmp" "$workflows_tmp"
    trap - RETURN

    finalize_n8n_api_auth

    if ! printf '%s' "$mapping_json" | jq -e '.workflowsById | type == "object"' >/dev/null 2>&1; then
        log ERROR "Constructed mapping missing workflowsById object"
        local mapping_preview mapping_length
        mapping_preview=$(printf '%s' "$mapping_json" | head -c 500)
        mapping_length=$(printf '%s' "$mapping_json" | wc -c | tr -d ' \n')
        mapping_length=${mapping_length:-0}
        log DEBUG "Mapping preview (first 500 chars): ${mapping_preview}$( [ "$mapping_length" -gt 500 ] && echo '…')"
        return 1
    fi

    if [[ -n "$result_ref" ]]; then
        printf -v "$result_ref" '%s' "$mapping_json"
    else
        printf '%s' "$mapping_json"
    fi
    return 0
}

validate_n8n_api_access() {
    local base_url="$1"
    local api_key="$2"
    local email="$3"
    local password="$4"
    local container_id="$5"
    local credential_name="$6"
    local container_credentials_path="${7:-}"

    if [[ -z "$base_url" ]]; then
        log ERROR "n8n base URL is required to validate API access."
        return 1
    fi

    base_url="${base_url%/}"

    if [[ -n "$api_key" ]]; then
        return test_n8n_api_connection "$base_url" "$api_key"
    fi

    if [[ -z "$email" || -z "$password" ]]; then
        if [[ -n "$credential_name" ]]; then
            if ! ensure_n8n_session_credentials "$container_id" "$credential_name" "$container_credentials_path"; then
                return 1
            fi
            email="$n8n_email"
            password="$n8n_password"
        fi
    fi

    if [[ -z "$email" || -z "$password" ]]; then
        log ERROR "Session authentication requires email/password but none are available. Configure N8N_LOGIN_CREDENTIAL_NAME or provide credentials."
        return 1
    fi

    if test_n8n_session_auth "$base_url" "$email" "$password" false; then
        cleanup_n8n_session
        return 0
    fi

    cleanup_n8n_session
    return 1
}

# Fetch projects using API key authentication
fetch_n8n_projects() {
    local base_url="$1"
    local api_key="$2"

    base_url="${base_url%/}"

    local response
    local http_status
    if ! response=$(curl -s -w "\n%{http_code}" \
        -H "X-N8N-API-KEY: $api_key" \
        -H "Accept: application/json" \
        "$base_url/rest/projects"); then
        log ERROR "Failed to fetch projects with API key authentication"
        return 1
    fi

    http_status=$(echo "$response" | tail -n1)
    local response_body=$(echo "$response" | head -n -1)

    if [[ "$http_status" != "200" ]]; then
        log ERROR "Projects API returned HTTP $http_status when using API key"
        log DEBUG "Projects API Response Body: $response_body"
        return 1
    fi

    response_body="$(sanitize_n8n_json_response "$response_body")"

    log DEBUG "Projects API (API key) success - received $(echo "$response_body" | wc -c) bytes"
    echo "$response_body"
    return 0
}

# Fetch workflows (including folder metadata) using API key authentication
fetch_workflows_with_folders() {
    local base_url="$1"
    local api_key="$2"

    base_url="${base_url%/}"

    local query_url="$base_url/rest/workflows?includeScopes=true&includeFolders=true&filter=%7B%22isArchived%22%3Afalse%7D&skip=0&take=1000&sortBy=updatedAt%3Adesc"

    local response
    local http_status
    if ! response=$(curl -s -w "\n%{http_code}" \
        -H "X-N8N-API-KEY: $api_key" \
        -H "Accept: application/json" \
        "$query_url"); then
        log ERROR "Failed to fetch workflows with API key authentication"
        return 1
    fi

    http_status=$(echo "$response" | tail -n1)
    local response_body=$(echo "$response" | head -n -1)

    if [[ "$http_status" != "200" ]]; then
        log ERROR "Workflows API returned HTTP $http_status when using API key"
        log DEBUG "Workflows API Response Body: $response_body"
        return 1
    fi

    response_body="$(sanitize_n8n_json_response "$response_body")"

    log DEBUG "Workflows API (API key) success - received $(echo "$response_body" | wc -c) bytes"
    echo "$response_body"
    return 0
}

# ============================================================================
# Session-based Authentication Functions for REST API (/rest/* endpoints)
# ============================================================================

# Global variable to store session cookie state
N8N_SESSION_COOKIE_FILE=""
N8N_SESSION_COOKIE_INITIALIZED="false"
N8N_SESSION_COOKIE_READY="false"
N8N_SESSION_REUSE_ENABLED="true"
# Records the current authentication path: "api_key", "session", or empty when undecided.
N8N_API_AUTH_MODE=""

ensure_n8n_session_credentials() {
    local container_id="$1"
    local credential_name="$2"
    local container_credentials_path="${3:-}"

    if [[ -n "${n8n_email:-}" && -n "${n8n_password:-}" ]]; then
        if [[ "${verbose:-false}" == "true" ]]; then
            log DEBUG "Using existing n8n session credentials from configuration"
        fi
        return 0
    fi

    if [[ -z "$credential_name" ]]; then
        log ERROR "Session credential name is required to load n8n session access credentials."
        return 1
    fi

    if [[ -z "$container_id" ]]; then
        log ERROR "Docker container ID is required to discover n8n session credentials."
        return 1
    fi

    local container_export_path="$container_credentials_path"
    local remove_container_file="false"
    if [[ -z "$container_export_path" ]]; then
        container_export_path="/tmp/n8n-session-credentials-$$.json"
        remove_container_file="true"
    fi

    local host_tmp_dir
    host_tmp_dir=$(mktemp -d -t n8n-session-credentials-XXXXXXXX)
    local host_tmp_file="$host_tmp_dir/credentials.json"

    if ! dockExec "$container_id" "n8n export:credentials --all --decrypted --output='$container_export_path'" false; then
        cleanup_temp_path "$host_tmp_dir"
        if [[ "$remove_container_file" == "true" ]]; then
            dockExec "$container_id" "rm -f '$container_export_path'" false >/dev/null 2>&1 || true
        fi
        log ERROR "Failed to export credentials from n8n container to locate '$credential_name'."
        return 1
    fi

    if ! docker cp "${container_id}:${container_export_path}" "$host_tmp_file" >/dev/null 2>&1; then
        cleanup_temp_path "$host_tmp_dir"
        if [[ "$remove_container_file" == "true" ]]; then
            dockExec "$container_id" "rm -f '$container_export_path'" false >/dev/null 2>&1 || true
        fi
        log ERROR "Unable to copy exported credentials from n8n container."
        return 1
    fi

    if [[ "$remove_container_file" == "true" ]]; then
        dockExec "$container_id" "rm -f '$container_export_path'" false >/dev/null 2>&1 || true
    fi

    if ! jq empty "$host_tmp_file" >/dev/null 2>&1; then
        cleanup_temp_path "$host_tmp_dir"
        log ERROR "Exported credentials payload is not valid JSON; cannot locate '$credential_name'."
        return 1
    fi

    local credential_json
    credential_json=$(jq -c --arg name "$credential_name" '
        (if type == "array" then . else (.data // []) end)
        | map(select(((.name // "") | ascii_downcase) == ($name | ascii_downcase) or ((.displayName // "") | ascii_downcase) == ($name | ascii_downcase)))
        | first // empty
    ' "$host_tmp_file" 2>/dev/null || true)

    if [[ -z "$credential_json" || "$credential_json" == "null" ]]; then
        cleanup_temp_path "$host_tmp_dir"
        log ERROR "Credential '$credential_name' not found in exported credentials."
        return 1
    fi

    local resolved_user
    local resolved_password
    resolved_user=$(jq -r '
        .data // {} |
        (.user // .username // .email // .login // .accountId // empty)
    ' <<<"$credential_json")
    resolved_password=$(jq -r '
        .data // {} |
        (.password // .pass // .userPassword // .apiKey // .token // empty)
    ' <<<"$credential_json")

    if [[ -z "$resolved_user" ]]; then
        cleanup_temp_path "$host_tmp_dir"
        log ERROR "Credential '$credential_name' does not contain a username or email field."
        return 1
    fi

    if [[ -z "$resolved_password" ]]; then
        cleanup_temp_path "$host_tmp_dir"
        log ERROR "Credential '$credential_name' does not contain a password or token field."
        return 1
    fi

    n8n_email="$(printf '%s' "$resolved_user" | tr -d '\r\n')"
    n8n_password="$(printf '%s' "$resolved_password" | tr -d '\r\n')"

    cleanup_temp_path "$host_tmp_dir"

    if [[ "${verbose:-false}" == "true" ]]; then
        log DEBUG "Loaded n8n session credential '$credential_name' (user: $n8n_email)"
    fi

    return 0
}

ensure_n8n_session_cookie_file() {
    if [[ "$N8N_SESSION_COOKIE_INITIALIZED" != "true" || -z "$N8N_SESSION_COOKIE_FILE" ]]; then
        local cookie_path
        cookie_path=$(mktemp -t n8n-session-cookies-XXXXXXXX)
        N8N_SESSION_COOKIE_FILE="$cookie_path"
        N8N_SESSION_COOKIE_INITIALIZED="true"
    fi
}

# Authenticate with n8n and get session cookie for REST API endpoints
authenticate_n8n_session() {
    local base_url="$1"
    local email="$2"
    local password="$3"
    local max_attempts="${4:-3}"  # Default to 3 attempts
    
    # Clean up URL
    base_url="${base_url%/}"

    ensure_n8n_session_cookie_file

    if [[ "$N8N_SESSION_COOKIE_READY" == "true" && -s "$N8N_SESSION_COOKIE_FILE" ]]; then
        if [[ "$verbose" == "true" ]]; then
            log DEBUG "Reusing existing n8n session cookie at $N8N_SESSION_COOKIE_FILE"
        fi
        return 0
    fi

    : >"$N8N_SESSION_COOKIE_FILE"
    N8N_SESSION_COOKIE_READY="false"
    
    local attempt=1
    local auth_response
    local http_status
    
    while [[ $attempt -le $max_attempts ]]; do
        
        # If this is a retry, prompt for new credentials
        if [[ $attempt -gt 1 ]]; then
            log WARN "Login attempt $((attempt-1)) failed. Please try again."
            printf "n8n email or LDAP login ID: "
            read -r email
            printf "n8n password: "
            read -r -s password
            echo  # Add newline after hidden input
        fi
        
        # Attempt to login and get session cookie with proper browser headers
        if ! auth_response=$(curl -s -w "\n%{http_code}" -c "$N8N_SESSION_COOKIE_FILE" \
            -X POST \
            -H "Content-Type: application/json" \
            -H "Accept: application/json, text/plain, */*" \
            -H "Accept-Language: en" \
            -H "Sec-Fetch-Dest: empty" \
            -H "Sec-Fetch-Mode: cors" \
            -H "Sec-Fetch-Site: same-origin" \
            -d "{\"emailOrLdapLoginId\":\"$email\",\"password\":\"$password\"}" \
            "$base_url/rest/login"); then
            log ERROR "Failed to connect to n8n login endpoint (attempt $attempt/$max_attempts)"
            if [[ $attempt -eq $max_attempts ]]; then
                log ERROR "Max attempts reached. Please check network connectivity and n8n server status."
                return 1
            fi
            ((attempt++))
            continue
        fi
        
        http_status=$(echo "$auth_response" | tail -n1)
        local response_body=$(echo "$auth_response" | head -n -1)
        
        if [[ "$http_status" == "200" ]]; then
            log SUCCESS "Successfully authenticated with n8n session!" >&2
            log DEBUG "Session cookie stored at $N8N_SESSION_COOKIE_FILE"
            N8N_SESSION_COOKIE_READY="true"
            return 0
        elif [[ "$http_status" == "401" ]]; then
            log ERROR "Invalid credentials (HTTP 401) - attempt $attempt/$max_attempts"
            if [[ $attempt -eq $max_attempts ]]; then
                log ERROR "Max login attempts reached. Please verify your credentials."
                : >"$N8N_SESSION_COOKIE_FILE"
                return 1
            fi
        elif [[ "$http_status" == "403" ]]; then
            log ERROR "Access forbidden (HTTP 403) - account may be locked or disabled"
            : >"$N8N_SESSION_COOKIE_FILE"
            return 1
        elif [[ "$http_status" == "429" ]]; then
            log ERROR "Too many requests (HTTP 429) - please wait before trying again"
            : >"$N8N_SESSION_COOKIE_FILE"
            return 1
        else
            log ERROR "Login failed with HTTP $http_status (attempt $attempt/$max_attempts)"
            if [[ $attempt -eq $max_attempts ]]; then
                log ERROR "Max attempts reached. Server may be experiencing issues."
                : >"$N8N_SESSION_COOKIE_FILE"
                return 1
            fi
        fi
        
        ((attempt++))
        
        # Add a small delay between attempts
        if [[ $attempt -le $max_attempts ]]; then
            sleep 1
        fi
    done
    
    return 1
}

# Fetch projects using session authentication (REST API)
fetch_n8n_projects_session() {
    local base_url="$1"
    
    # Clean up URL
    base_url="${base_url%/}"
    
    local response
    local http_status
    if ! response=$(curl -s -w "\n%{http_code}" -b "$N8N_SESSION_COOKIE_FILE" \
        -H "Accept: application/json, text/plain, */*" \
        -H "Accept-Language: en" \
        -H "Sec-Fetch-Dest: empty" \
        -H "Sec-Fetch-Mode: cors" \
        -H "Sec-Fetch-Site: same-origin" \
        "$base_url/rest/projects"); then
        log ERROR "Failed to fetch projects from n8n REST API"
        return 1
    fi
    
    http_status=$(echo "$response" | tail -n1)
    local response_body=$(echo "$response" | head -n -1)
    
    if [[ "$http_status" != "200" ]]; then
        log ERROR "Failed to fetch projects via session (HTTP $http_status)"
        log DEBUG "Projects API Response Body: $response_body"
        return 1
    fi
    
    response_body="$(sanitize_n8n_json_response "$response_body")"

    log DEBUG "Projects API Success - received $(echo "$response_body" | wc -c) bytes"
    echo "$response_body"
    return 0
}

# Fetch workflows with folders using session authentication (REST API)
fetch_workflows_with_folders_session() {
    local base_url="$1"
    local project_id="$2"
    
    # Clean up URL
    base_url="${base_url%/}"
    
    # Construct the query URL with proper parameters (URL encoded)
    local query_url="$base_url/rest/workflows?includeScopes=true&includeFolders=true"
    
    # Add project filter if provided, otherwise get all workflows
    if [[ -n "$project_id" ]]; then
        # Filter by specific project: isArchived=false, parentFolderId=0, projectId=<id>
        query_url="${query_url}&filter=%7B%22isArchived%22%3Afalse%2C%22parentFolderId%22%3A%220%22%2C%22projectId%22%3A%22${project_id}%22%7D"
    else
        # Get all non-archived workflows
        query_url="${query_url}&filter=%7B%22isArchived%22%3Afalse%7D"
    fi
    
    # Add pagination and sorting
    query_url="${query_url}&skip=0&take=1000&sortBy=updatedAt%3Adesc"
    
    local response
    local http_status
    if ! response=$(curl -s -w "\n%{http_code}" -b "$N8N_SESSION_COOKIE_FILE" \
        -H "Accept: application/json, text/plain, */*" \
        -H "Accept-Language: en" \
        -H "Sec-Fetch-Dest: empty" \
        -H "Sec-Fetch-Mode: cors" \
        -H "Sec-Fetch-Site: same-origin" \
        "$query_url"); then
        log ERROR "Failed to fetch workflows from n8n REST API"
        return 1
    fi
    
    http_status=$(echo "$response" | tail -n1)
    local response_body=$(echo "$response" | head -n -1)
    
    if [[ "$http_status" != "200" ]]; then
        log ERROR "Failed to fetch workflows with folders via session (HTTP $http_status)"
        log DEBUG "Workflows API Response Body: $response_body"
        log DEBUG "Query URL was: $query_url"
        return 1
    fi
    
    response_body="$(sanitize_n8n_json_response "$response_body")"

    log DEBUG "Workflows API Success - received $(echo "$response_body" | wc -c) bytes"
    echo "$response_body"
    return 0
}

# Test session-based authentication
test_n8n_session_auth() {
    local base_url="$1"
    local email="$2"
    local password="$3"
    local verbose="${4:-false}"
    
    if $verbose; then
        log INFO "Testing n8n session authentication to: $base_url"
    fi
    
    # Authenticate first
    if ! authenticate_n8n_session "$base_url" "$email" "$password"; then
        return 1
    fi
    
    # Test with a simple API call
    local response
    local http_status
    if ! response=$(curl -s -w "\n%{http_code}" -b "$N8N_SESSION_COOKIE_FILE" "$base_url/rest/workflows?limit=1" 2>/dev/null); then
        log ERROR "Failed to test session authentication"
        rm -f "$N8N_SESSION_COOKIE_FILE"
        return 1
    fi
    
    http_status=$(echo "$response" | tail -n1)
    local response_body=$(echo "$response" | head -n -1)
    
    if [[ "$http_status" == "200" ]]; then
        if $verbose; then
            log SUCCESS "n8n session authentication successful!"
            local workflow_count
            workflow_count=$(echo "$response_body" | jq -r '.data | length // 0' 2>/dev/null || echo "0")
            log INFO "Found $workflow_count workflows accessible via session"
        fi
        return 0
    else
        log ERROR "Session authentication test failed with HTTP $http_status"
        rm -f "$N8N_SESSION_COOKIE_FILE"
        return 1
    fi
}

# Cleanup session cookie file
cleanup_n8n_session() {
    local mode="${1:-auto}"

    if [[ "$mode" == "force" ]]; then
        if [[ -n "$N8N_SESSION_COOKIE_FILE" && -f "$N8N_SESSION_COOKIE_FILE" ]]; then
            rm -f "$N8N_SESSION_COOKIE_FILE"
            log DEBUG "Cleaned up session cookie file (EXIT trap)"
        fi
        N8N_SESSION_COOKIE_FILE=""
        N8N_SESSION_COOKIE_INITIALIZED="false"
        N8N_SESSION_COOKIE_READY="false"
        return 0
    fi

    if [[ "$N8N_SESSION_REUSE_ENABLED" != "true" ]]; then
        if [[ -n "$N8N_SESSION_COOKIE_FILE" && -f "$N8N_SESSION_COOKIE_FILE" ]]; then
            rm -f "$N8N_SESSION_COOKIE_FILE"
            log DEBUG "Cleaned up session cookie file"
        fi
        N8N_SESSION_COOKIE_FILE=""
        N8N_SESSION_COOKIE_INITIALIZED="false"
        N8N_SESSION_COOKIE_READY="false"
    fi

    return 0
}

prepare_n8n_api_auth() {
    local container_id="$1"
    local container_credentials_path="${2:-}"

    if [[ "$N8N_API_AUTH_MODE" == "api_key" ]]; then
        return 0
    fi

    if [[ -z "$n8n_base_url" ]]; then
        log ERROR "n8n base URL is required to interact with the API."
        return 1
    fi

    n8n_base_url="${n8n_base_url%/}"

    if [[ "$N8N_SESSION_COOKIE_READY" == "true" && -f "$N8N_SESSION_COOKIE_FILE" ]]; then
        if [[ "$verbose" == "true" ]]; then
            if [[ "$N8N_API_AUTH_MODE" == "session" ]]; then
                log DEBUG "Reusing existing n8n session."
            else
                log DEBUG "Reusing cached n8n session"
            fi
        fi
        N8N_API_AUTH_MODE="session"
        return 0
    fi

    if [[ "$N8N_API_AUTH_MODE" == "session" ]]; then
        N8N_API_AUTH_MODE=""
    fi

    if [[ -n "${n8n_api_key:-}" ]]; then
        N8N_API_AUTH_MODE="api_key"
        return 0
    fi

    if [[ -z "${n8n_session_credential:-}" ]]; then
        log ERROR "n8n session credential name not configured; cannot authenticate without API key."
        return 1
    fi

    if ! ensure_n8n_session_credentials "$container_id" "$n8n_session_credential" "$container_credentials_path"; then
        return 1
    fi

    if ! authenticate_n8n_session "$n8n_base_url" "$n8n_email" "$n8n_password" 1; then
        log ERROR "Unable to authenticate with n8n session for folder structure operations."
        return 1
    fi

    N8N_API_AUTH_MODE="session"
    return 0
}

finalize_n8n_api_auth() {
    # Session will be cleaned up by EXIT trap if needed
    # No need to log here as this is called during normal finalization
    N8N_API_AUTH_MODE=""
}

n8n_api_request() {
    local method="$1"
    local endpoint="$2"
    local payload="${3:-}"

    if [[ -z "$N8N_API_AUTH_MODE" ]]; then
        log ERROR "n8n API authentication not initialised."
        return 1
    fi

    local url="$n8n_base_url/rest${endpoint}"
    local -a curl_args=("-sS" "-w" "\n%{http_code}" "-X" "$method" "$url")

    if [[ "$method" != "GET" ]]; then
        curl_args+=("-H" "Content-Type: application/json")
    fi

    curl_args+=("-H" "Accept: application/json")

    if [[ "$N8N_API_AUTH_MODE" == "api_key" ]]; then
        curl_args+=("-H" "X-N8N-API-KEY: $n8n_api_key")
    else
        curl_args+=("-b" "$N8N_SESSION_COOKIE_FILE")
    fi

    if [[ -n "$payload" ]]; then
        curl_args+=("-d" "$payload")
    fi

    local response
    N8N_API_LAST_STATUS=""
    N8N_API_LAST_BODY=""
    N8N_API_LAST_ERROR_CATEGORY=""

    if ! response=$(curl "${curl_args[@]}" 2>/dev/null); then
        log ERROR "Failed to contact n8n API endpoint $endpoint"
        return 1
    fi

    local http_status
    http_status=$(echo "$response" | tail -n1)
    N8N_API_LAST_STATUS="$http_status"
    local body_raw
    body_raw=$(echo "$response" | head -n -1)
    N8N_API_LAST_BODY="$body_raw"

    if [[ "$http_status" != 2* && "$http_status" != 3* ]]; then
        local license_block="false"
        if [[ "$http_status" == "403" ]]; then
            if printf '%s' "$body_raw" | grep -qi 'plan lacks license'; then
                license_block="true"
            fi
        fi

        if [[ "$license_block" == "true" ]]; then
            N8N_API_LAST_ERROR_CATEGORY="license"
            if [[ "$verbose" == "true" && -n "$body_raw" ]]; then
                log DEBUG "n8n API response: $body_raw"
            fi
        else
            if [[ -n "$body_raw" ]]; then
                log ERROR "n8n API request failed (HTTP $http_status) for $endpoint"
                log DEBUG "n8n API response: $body_raw"
            else
                log ERROR "n8n API request failed (HTTP $http_status) for $endpoint"
            fi
        fi
        return 1
    fi

    local body
    body="$(sanitize_n8n_json_response "$body_raw")"
    N8N_API_LAST_BODY="$body"

    if [[ "$verbose" == "true" ]]; then
        local body_len preview truncated
        body_len="$(printf '%s' "$body" | wc -c | tr -d ' \n')"
        preview="$(printf '%s' "$body" | tr '\n' ' ' | head -c 200)"
        truncated=""
        if [[ "${body_len:-0}" -gt 200 ]]; then
            truncated="…"
        fi
        if [[ -n "$preview" ]]; then
            log DEBUG "n8n API request $endpoint returned ${body_len:-0} bytes (preview: ${preview}${truncated})"
        else
            log DEBUG "n8n API request $endpoint returned ${body_len:-0} bytes"
        fi
    fi

    printf '%s' "$body"
    return 0
}

n8n_api_get_projects() {
    n8n_api_request "GET" "/projects?skip=0&take=250"
}

n8n_api_get_folders() {
    local projects_json
    if ! projects_json=$(n8n_api_get_projects); then
        log ERROR "Unable to retrieve projects while enumerating folders"
        return 1
    fi

    local folders_tmp
    folders_tmp=$(mktemp -t n8n-folders-XXXXXXXX.json)
    printf '[]' > "$folders_tmp"

    local found_any="false"
    local saw_not_found="false"

    while IFS= read -r project_id; do
        [[ -z "$project_id" ]] && continue

        local folder_response
        if ! folder_response=$(n8n_api_request "GET" "/projects/$project_id/folders?skip=0&take=1000"); then
            if [[ "${N8N_API_LAST_STATUS:-}" == "404" ]]; then
                saw_not_found="true"
            else
                local status="${N8N_API_LAST_STATUS:-unknown}"
                local category="${N8N_API_LAST_ERROR_CATEGORY:-}"
                if [[ "$category" == "license" ]]; then
                    local message=""
                    if [[ -n "${N8N_API_LAST_BODY:-}" ]]; then
                        message=$(printf '%s' "${N8N_API_LAST_BODY}" | jq -r '.message // empty' 2>/dev/null || printf '')
                    fi
                    if [[ -n "$message" ]]; then
                        log INFO "Skipping folder discovery for project $project_id due to license restriction (HTTP $status, message: $message)"
                    else
                        log INFO "Skipping folder discovery for project $project_id due to license restriction (HTTP $status)"
                    fi
                else
                    log WARN "Failed to fetch folders for project $project_id (HTTP $status)"
                fi
            fi
            continue
        fi

        found_any="true"

        local normalized
        if ! normalized=$(printf '%s' "$folder_response" | jq -c --arg pid "$project_id" '
            (if type == "array" then . else (.data // []) end)
            | map(.projectId = (.projectId // $pid))
        ' 2>/dev/null); then
            log WARN "Unable to parse folder list for project $project_id"
            continue
        fi

        local normalized_tmp
        normalized_tmp=$(mktemp -t n8n-folder-normalized-XXXXXXXX.json)
        printf '%s' "$normalized" > "$normalized_tmp"
        if ! jq -s -c '.[0] + (.[1] // [])' "$folders_tmp" "$normalized_tmp" > "${folders_tmp}.tmp"; then
            log WARN "Failed to merge folder list for project $project_id"
            rm -f "$normalized_tmp" "${folders_tmp}.tmp"
            continue
        fi
        mv "${folders_tmp}.tmp" "$folders_tmp"
        rm -f "$normalized_tmp"
    done < <(printf '%s' "$projects_json" | jq -r '
        if type == "array" then .[] else (.data // [])[] end
        | .id // empty
    ')

    if [[ "$found_any" != "true" && "$saw_not_found" == "true" ]]; then
        rm -f "$folders_tmp"
        if ! n8n_api_request "GET" "/folders?skip=0&take=1000"; then
            return 1
        fi
        return 0
    fi

    local combined
    combined=$(cat "$folders_tmp")
    rm -f "$folders_tmp"
    printf '%s' "$combined"
    return 0
}

n8n_api_get_workflows() {
    n8n_api_request "GET" "/workflows?includeScopes=true&includeFolders=true&filter=%7B%22isArchived%22%3Afalse%7D&skip=0&take=2000&sortBy=updatedAt%3Adesc"
}

n8n_api_get_workflow() {
    local workflow_id="$1"

    if [[ -z "$workflow_id" ]]; then
        log WARN "Workflow id is required when requesting workflow details."
        return 1
    fi

    if ! n8n_api_request "GET" "/workflows/${workflow_id}"; then
        return 1
    fi

    return 0
}

n8n_api_archive_workflow() {
    local workflow_id="$1"

    if [[ -z "$workflow_id" ]]; then
        log WARN "Skipping archive request - workflow id not provided."
        return 1
    fi

    local archive_response=""
    if archive_response=$(n8n_api_request "POST" "/workflows/${workflow_id}/archive"); then
        if [[ "$verbose" == "true" && -n "$archive_response" ]]; then
            local preview suffix response_len
            preview=$(printf '%s' "$archive_response" | tr '\n' ' ' | head -c 200)
            response_len=$(printf '%s' "$archive_response" | wc -c | tr -d ' \n')
            suffix=""
            if [[ ${response_len:-0} -gt 200 ]]; then
                suffix="…"
            fi
            log DEBUG "Archive response for workflow $workflow_id: ${preview}${suffix}"
        fi
        return 0
    fi

    local last_status="${N8N_API_LAST_STATUS:-}"
    if [[ "$last_status" == "409" ]]; then
        log DEBUG "Workflow $workflow_id already archived (HTTP 409); continuing."
        return 0
    fi

    if [[ "$last_status" == "404" ]]; then
        log DEBUG "Workflow $workflow_id not found when archiving; assuming it was already removed."
        return 0
    fi

    local payload
    payload=$(jq -n '{isArchived: true}')
    if n8n_api_request "PATCH" "/workflows/${workflow_id}" "$payload"; then
        return 0
    fi

    last_status="${N8N_API_LAST_STATUS:-}"
    if [[ "$last_status" == "409" ]]; then
        log DEBUG "Workflow $workflow_id already archived when patching (HTTP 409); continuing."
        return 0
    fi

    if [[ "$last_status" == "404" ]]; then
        log DEBUG "Workflow $workflow_id missing when patching archive; treating as already removed."
        return 0
    fi

    log WARN "Failed to archive workflow $workflow_id via n8n API (HTTP ${last_status:-unknown})."
    return 1
}

n8n_api_create_folder() {
    local name="$1"
    local project_id="$2"
    local parent_id="${3:-}"

    if [[ "$parent_id" == "null" ]]; then
        parent_id=""
    fi

    if [[ -z "$project_id" ]]; then
        log ERROR "Project ID required when creating n8n folder '$name'"
        return 1
    fi

    local payload
    payload=$(jq -n \
        --arg name "$name" \
        --arg projectId "$project_id" \
        --arg parentId "${parent_id:-}" \
        '{
            name: $name,
            projectId: $projectId
        } + (if ($parentId // "") == "" then {} else {parentFolderId: $parentId} end)')

    n8n_api_request "POST" "/projects/$project_id/folders" "$payload"
}

n8n_api_update_folder_parent() {
    local project_id="$1"
    local folder_id="$2"
    local parent_id="${3:-}"

    if [[ "$parent_id" == "null" ]]; then
        parent_id=""
    fi

    if [[ -z "$project_id" ]]; then
        log ERROR "Project ID required when updating folder $folder_id"
        return 1
    fi

    if [[ -z "$folder_id" ]]; then
        log ERROR "Folder ID required when updating project $project_id"
        return 1
    fi

    local payload
    payload=$(jq -n \
        --arg parentId "${parent_id:-}" \
        '(if ($parentId // "") == "" then {} else {parentFolderId: $parentId} end)')

    n8n_api_request "PATCH" "/projects/$project_id/folders/$folder_id" "$payload"
}

n8n_api_update_workflow_assignment() {
    local workflow_id="$1"
    local project_id="$2"
    local folder_id="${3:-}"
    local version_id="${4:-}"
    local version_mode="${5:-auto}"

    if [[ -z "$workflow_id" ]]; then
        log WARN "Skipping workflow reassignment - missing workflow id"
        return 1
    fi

    if [[ -z "$project_id" ]]; then
        log WARN "Skipping workflow $workflow_id assignment update - missing project id"
        return 1
    fi

    local normalized_folder_id="${folder_id:-}"
    if [[ "$normalized_folder_id" == "null" ]]; then
        normalized_folder_id=""
    fi

    local include_folder="false"
    if [[ -n "$normalized_folder_id" ]]; then
        include_folder="true"
    else
        normalized_folder_id="$N8N_PROJECT_ROOT_ID"
        include_folder="true"
    fi

    local resolved_version_mode="$version_mode"
    if [[ "$resolved_version_mode" != "string" && "$resolved_version_mode" != "null" ]]; then
        if [[ -z "$version_id" || "$version_id" == "null" ]]; then
            resolved_version_mode="null"
        else
            resolved_version_mode="string"
        fi
    elif [[ "$resolved_version_mode" == "string" && ( -z "$version_id" || "$version_id" == "null" ) ]]; then
        resolved_version_mode="null"
    fi

    local jq_args=(-n --arg projectId "$project_id" --arg includeFolder "$include_folder" --arg folderId "$normalized_folder_id" --arg versionMode "$resolved_version_mode" --arg versionId "${version_id:-}")

    local payload
    payload=$(jq "${jq_args[@]}" '
        {
            homeProject: {
                id: $projectId
            }
        }
        + (if $includeFolder == "true" then { parentFolderId: (if ($folderId // "") == "" then null else $folderId end) } else {} end)
        + (if $versionMode == "string" then { versionId: $versionId }
           elif $versionMode == "null" then { versionId: null }
           else {} end)
    ')

    if [[ "$resolved_version_mode" == "null" && "$verbose" == "true" ]]; then
        log DEBUG "Updating workflow $workflow_id with null versionId payload."
    fi

    local update_response
    if ! update_response=$(n8n_api_request "PATCH" "/workflows/$workflow_id" "$payload"); then
        return 1
    fi

    if [[ "$verbose" == "true" ]]; then
        local preview response_len suffix
        preview=$(printf '%s' "$update_response" | tr '\n' ' ' | head -c 200)
        response_len=$(printf '%s' "$update_response" | wc -c | tr -d ' \n')
        suffix=""
        if [[ ${response_len:-0} -gt 200 ]]; then
            suffix="…"
        fi
        if [[ -n "$preview" ]]; then
            log DEBUG "Workflow $workflow_id assignment update response preview: ${preview}${suffix}"
        fi
    fi

    return 0
}