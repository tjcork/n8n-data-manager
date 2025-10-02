#!/usr/bin/env bash
# =========================================================
# lib/n8n-api.sh - n8n REST API functions for n8n-manager
# =========================================================
# All functions for interacting with n8n's REST API to get
# folder structure and workflow organization data

# Source common utilities
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Test n8n API connection using appropriate authentication method
test_n8n_api_connection() {
    local base_url="$1"
    local api_key="$2"
    
    log INFO "Testing n8n API connection to: $base_url"
    
    # Clean up URL (remove trailing slash)
    base_url="${base_url%/}"
    
    # Test API connection with basic endpoint
    local response
    local http_status
    if ! response=$(curl -s -w "\\n%{http_code}" -H "X-N8N-API-KEY: $api_key" "$base_url/rest/workflows?limit=1" 2>/dev/null); then
        log ERROR "Failed to connect to n8n API at: $base_url"
        return 1
    fi
    
    http_status=$(echo "$response" | tail -n1)
    local response_body=$(echo "$response" | head -n -1)
    
    if [[ "$http_status" == "401" ]]; then
        log ERROR "n8n API authentication failed. Please check your API key."
        return 1
    elif [[ "$http_status" == "404" ]]; then
        log ERROR "n8n API endpoint not found. Please check the URL and ensure n8n version supports REST API."
        return 1
    elif [[ "$http_status" != "200" ]]; then
        log ERROR "n8n API connection failed with HTTP status: $http_status"
        log DEBUG "Response body: $response_body"
        return 1
    fi
    
    log SUCCESS "n8n API connection successful!"
    return 0
}

# Track whether we've already pulled session credentials from n8n
_n8n_session_credentials_loaded=false

# Ensure session authentication credentials are available by loading them from
# the configured n8n credential inside the Docker container when needed.
#
# Arguments:
#   $1 - Docker container ID/name running n8n
#   $2 - Credential name inside n8n (e.g. "N8N REST BACKUP")
#   $3 - Optional existing credentials JSON path inside the container
ensure_n8n_session_credentials() {
    local container_id="$1"
    local credential_name="$2"
    local container_credentials_path="${3:-}"

    if [[ -n "${n8n_email:-}" && -n "${n8n_password:-}" ]]; then
        _n8n_session_credentials_loaded=true
        return 0
    fi

    if [[ -z "$credential_name" ]]; then
        log ERROR "Session credential name not configured. Set N8N_LOGIN_CREDENTIAL_NAME."
        return 1
    fi

    if [[ -z "$container_id" ]]; then
        log ERROR "Container ID required to load n8n session credential '$credential_name'."
        return 1
    fi

    local credential_payload=""

    if [[ -n "$container_credentials_path" ]]; then
        if docker exec "$container_id" sh -c "[ -f '$container_credentials_path' ]" 2>/dev/null; then
            if ! credential_payload=$(docker exec "$container_id" sh -c "cat $container_credentials_path" 2>/dev/null); then
                credential_payload=""
            fi
        fi
    fi

    if [[ -z "$credential_payload" ]]; then
        local temp_path="/tmp/n8n-session-credential-$$.json"
        if ! docker exec "$container_id" sh -c "n8n export:credentials --all --decrypted --output=$temp_path >/dev/null 2>&1"; then
            log ERROR "Failed to export credentials from n8n container to locate '$credential_name'."
            return 1
        fi

        if ! credential_payload=$(docker exec "$container_id" sh -c "cat $temp_path" 2>/dev/null); then
            credential_payload=""
        fi

        docker exec "$container_id" sh -c "rm -f $temp_path" >/dev/null 2>&1 || true
    fi

    if [[ -z "$credential_payload" ]]; then
        log ERROR "Unable to read exported credentials when searching for '$credential_name'."
        return 1
    fi

    local credential_entry
    if ! credential_entry=$(printf '%s' "$credential_payload" | jq -c --arg name "$credential_name" '
        (if type == "object" and has("data") then .data else . end)
        | (if type == "array" then . else [] end)
        | map(select((.name // "") == $name))
        | first // empty
    ' 2>/dev/null); then
        log ERROR "Failed to parse credentials JSON while locating '$credential_name'."
        return 1
    fi

    if [[ -z "$credential_entry" || "$credential_entry" == "null" ]]; then
        log ERROR "Credential named '$credential_name' not found in n8n instance."
        return 1
    fi

    local session_user
    local session_password
    session_user=$(printf '%s' "$credential_entry" | jq -r '.data.user // .data.email // empty' 2>/dev/null)
    session_password=$(printf '%s' "$credential_entry" | jq -r '.data.password // empty' 2>/dev/null)

    if [[ -z "$session_user" || -z "$session_password" || "$session_user" == "null" || "$session_password" == "null" ]]; then
        log ERROR "Credential '$credential_name' is missing required Basic Auth fields (user/password)."
        return 1
    fi

    n8n_email="$session_user"
    n8n_password="$session_password"
    _n8n_session_credentials_loaded=true
    log DEBUG "Loaded session credentials from n8n credential '$credential_name'"
    return 0
}

# Comprehensive API validation - tests all available authentication methods
# Build mapping of workflows to sanitized folder paths
get_workflow_folder_mapping() {
    local container_id="$1"
    local container_credentials_path="${2:-}"
    local base_url="$n8n_base_url"
    local api_key="$n8n_api_key"
    local email="$n8n_email"
    local password="$n8n_password"

    if [[ -z "$base_url" ]]; then
        log ERROR "n8n API URL not configured. Please set N8N_BASE_URL"
        return 1
    fi

    base_url="${base_url%/}"

    local projects_response=""
    local workflows_response=""
    local using_session=false
    local responses_ready="false"
    local used_api_key="false"

    # Prefer API key if supplied
    if [[ -n "$api_key" ]]; then
        log DEBUG "Fetching workflow metadata using API key authentication"
        local api_projects=""
        local api_workflows=""
          if api_projects=$(fetch_n8n_projects "$base_url" "$api_key") && \
              api_workflows=$(fetch_workflows_with_folders "$base_url" "$api_key"); then
                log SUCCESS "Retrieved workflow metadata via API key" >&2
            projects_response="$api_projects"
            workflows_response="$api_workflows"
            responses_ready="true"
            used_api_key="true"
        else
            log WARN "API key request failed (see above). Will retry using session authentication"
        fi
    fi

    # Fall back to session auth if API key not usable
    if [[ "$responses_ready" != "true" ]]; then
        if [[ -z "$email" || -z "$password" ]]; then
            if [[ -n "${n8n_session_credential:-}" ]]; then
                if ! ensure_n8n_session_credentials "$container_id" "$n8n_session_credential" "$container_credentials_path"; then
                    return 1
                fi
                email="$n8n_email"
                password="$n8n_password"
            else
                log ERROR "Session credentials not configured. Set N8N_LOGIN_CREDENTIAL_NAME or provide email/password."
                return 1
            fi
        fi

        log DEBUG "Fetching workflow metadata using session authentication"
        if ! authenticate_n8n_session "$base_url" "$email" "$password" 1; then
            log ERROR "Session authentication failed"
            return 1
        fi

        using_session=true

        local session_projects=""
        local session_workflows=""

        if ! session_projects=$(fetch_n8n_projects_session "$base_url"); then
            cleanup_n8n_session
            return 1
        fi
        if ! session_workflows=$(fetch_workflows_with_folders_session "$base_url" ""); then
            cleanup_n8n_session
            return 1
        fi

        projects_response="$session_projects"
        workflows_response="$session_workflows"
        responses_ready="true"
    fi

    if [[ "$responses_ready" != "true" ]]; then
        log ERROR "Unable to retrieve workflow metadata via API key or session authentication"
        return 1
    fi

    # Normalize responses when using API key
    if [[ "$used_api_key" == "true" && "$using_session" == "false" ]]; then
        projects_response="$(echo "$projects_response" | jq 'if type == "object" then . else {data: .} end' 2>/dev/null)"
        workflows_response="$(echo "$workflows_response" | jq 'if type == "object" then . else {data: .} end' 2>/dev/null)"
    fi

    if [[ -z "$projects_response" || -z "$workflows_response" ]]; then
        log ERROR "Failed to retrieve workflow metadata from n8n"
        if $using_session; then
            cleanup_n8n_session
        fi
        return 1
    fi

    # Strip Windows-style carriage returns to avoid jq parsing issues
    projects_response="$(printf '%s' "$projects_response" | tr -d '\r')"
    workflows_response="$(printf '%s' "$workflows_response" | tr -d '\r')"

    if [ "$verbose" = "true" ]; then
        local projects_preview
        local workflows_preview
        projects_preview="$(printf '%s' "$projects_response" | tr '\n' ' ' | head -c 200)"
        workflows_preview="$(printf '%s' "$workflows_response" | tr '\n' ' ' | head -c 200)"
        log DEBUG "Projects response preview: ${projects_preview}$( [ $(printf '%s' "$projects_response" | wc -c) -gt 200 ] && echo '…')"
        log DEBUG "Workflows response preview: ${workflows_preview}$( [ $(printf '%s' "$workflows_response" | wc -c) -gt 200 ] && echo '…')"
    fi

    if ! printf '%s' "$projects_response" | jq empty >/dev/null 2>&1; then
        local sample
        sample="$(printf '%s' "$projects_response" | tr '\n' ' ' | head -c 200)"
        log ERROR "Projects response is not valid JSON (sample: ${sample}...)"
        if $using_session; then
            cleanup_n8n_session
        fi
        return 1
    fi

    if ! printf '%s' "$workflows_response" | jq empty >/dev/null 2>&1; then
        local sample
        sample="$(printf '%s' "$workflows_response" | tr '\n' ' ' | head -c 200)"
        log ERROR "Workflows response is not valid JSON (sample: ${sample}...)"
        if $using_session; then
            cleanup_n8n_session
        fi
        return 1
    fi

    local mapping_json
    if ! mapping_json=$(jq -n \
        --argjson projects "$projects_response" \
        --argjson workflows "$workflows_response" '
            def sanitize($value):
                ($value // "")
                | gsub("\\s+"; "_")
                | gsub("/"; "_")
                | gsub("[^A-Za-z0-9._-]"; "");

            def normalize_id($value):
                if $value == null then null
                else
                    ($value | tostring) as $str |
                    if ($str | gsub("\\s"; "")) == "" or $str == "null" then null else $str end
                end;

            def folder_lookup:
                ($workflows.data // [])
                | map(select(.resource == "folder"))
                | map(
                    (normalize_id(.id)) as $fid |
                    if $fid == null then empty else
                        {
                            key: $fid,
                            value: {
                                id: $fid,
                                name: (.name // "Folder"),
                                slug: sanitize(.name // "Folder"),
                                parentId: normalize_id(.parentFolderId // (.parentFolder.id // null))
                            }
                        }
                    end
                )
                | from_entries;

            def folder_path($folderId; $folders):
                (normalize_id($folderId)) as $fid |
                if $fid == null then []
                else
                    ($folders[$fid] // null) as $folder |
                    if $folder == null then []
                    else
                        (folder_path($folder.parentId; $folders) + [{name: $folder.name, slug: $folder.slug}])
                    end
                end;

            folder_lookup as $folders_by_id |

            (
                ($projects.data // [])
                | map({
                    id: (.id // "default"),
                    name: (if (.type // "") == "personal" then "Personal" else (.name // "Project") end),
                    slug: sanitize(if (.type // "") == "personal" then "Personal" else (.name // "Project") end)
                })
            ) as $project_lookup |

            (
                ($project_lookup | map({ (.id): {name: .name, slug: .slug} }) | add) // {}
            ) as $projects_by_id |

            (
                ($workflows.data // [])
                | map(select(.resource != "folder"))
                | map(
                    (folder_path(.parentFolderId // (.parentFolder.id // null); $folders_by_id)) as $folder_chain |
                    (.homeProject.id // "default") as $pid |
                    ($projects_by_id[$pid] // {name: "Personal", slug: "Personal"}) as $project_info |
                    {
                        id: (.id | tostring),
                        name: (.name // "Unnamed Workflow"),
                        project: {
                            id: $pid,
                            name: $project_info.name,
                            slug: $project_info.slug
                        },
                        folders: $folder_chain,
                        relativePath: (
                            [$project_info.slug]
                            + ($folder_chain | map(.slug))
                            | join("/")
                        ),
                        displayPath: (
                            [$project_info.name]
                            + ($folder_chain | map(.name))
                            | join("/")
                        )
                    }
                )
            ) as $workflow_list |
            {
                fetchedAt: (now | todateiso8601),
                workflows: $workflow_list,
                workflowsById: ($workflow_list | map({key: .id, value: .}) | from_entries)
            }
        '); then
        log ERROR "Failed to construct workflow mapping JSON"
        if $using_session; then
            cleanup_n8n_session
        fi
        return 1
    fi

    if $using_session; then
        cleanup_n8n_session
    fi

    if ! printf '%s' "$mapping_json" | jq -e '.workflowsById | type == "object"' >/dev/null 2>&1; then
        log ERROR "Constructed mapping missing workflowsById object"
        local mapping_preview mapping_length
        mapping_preview=$(printf '%s' "$mapping_json" | head -c 500)
    mapping_length=$(printf '%s' "$mapping_json" | wc -c | tr -d ' \n')
    mapping_length=${mapping_length:-0}
        log DEBUG "Mapping preview (first 500 chars): ${mapping_preview}$( [ "$mapping_length" -gt 500 ] && echo '…')"
        return 1
    fi

    echo "$mapping_json"
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

    log DEBUG "Workflows API (API key) success - received $(echo "$response_body" | wc -c) bytes"
    echo "$response_body"
    return 0
}

# ============================================================================
# Session-based Authentication Functions for REST API (/rest/* endpoints)
# ============================================================================

# Global variable to store session cookie file path
N8N_SESSION_COOKIE_FILE="/tmp/n8n-session-cookies-$$"
N8N_API_AUTH_MODE=""

# Authenticate with n8n and get session cookie for REST API endpoints
authenticate_n8n_session() {
    local base_url="$1"
    local email="$2"
    local password="$3"
    local max_attempts="${4:-3}"  # Default to 3 attempts
    
    # Clean up URL
    base_url="${base_url%/}"
    
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
            
            return 0
        elif [[ "$http_status" == "401" ]]; then
            log ERROR "Invalid credentials (HTTP 401) - attempt $attempt/$max_attempts"
            if [[ $attempt -eq $max_attempts ]]; then
                log ERROR "Max login attempts reached. Please verify your credentials."
                return 1
            fi
        elif [[ "$http_status" == "403" ]]; then
            log ERROR "Access forbidden (HTTP 403) - account may be locked or disabled"
            return 1
        elif [[ "$http_status" == "429" ]]; then
            log ERROR "Too many requests (HTTP 429) - please wait before trying again"
            return 1
        else
            log ERROR "Login failed with HTTP $http_status (attempt $attempt/$max_attempts)"
            if [[ $attempt -eq $max_attempts ]]; then
                log ERROR "Max attempts reached. Server may be experiencing issues."
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
    if [[ -f "$N8N_SESSION_COOKIE_FILE" ]]; then
        rm -f "$N8N_SESSION_COOKIE_FILE"
        log DEBUG "Cleaned up session cookie file"
    fi
}

prepare_n8n_api_auth() {
    local container_id="$1"
    local container_credentials_path="${2:-}"

    if [[ -z "$n8n_base_url" ]]; then
        log ERROR "n8n base URL is required to interact with the API."
        return 1
    fi

    n8n_base_url="${n8n_base_url%/}"

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
    if [[ "$N8N_API_AUTH_MODE" == "session" ]]; then
        cleanup_n8n_session
    fi
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
    if ! response=$(curl "${curl_args[@]}" 2>/dev/null); then
        log ERROR "Failed to contact n8n API endpoint $endpoint"
        return 1
    fi

    local http_status
    http_status=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | head -n -1)

    if [[ "$http_status" != 2* && "$http_status" != 3* ]]; then
        log ERROR "n8n API request failed (HTTP $http_status) for $endpoint"
        if [[ -n "$body" ]]; then
            log DEBUG "n8n API response: $body"
        fi
        return 1
    fi

    printf '%s' "$body"
    return 0
}

n8n_api_get_projects() {
    n8n_api_request "GET" "/projects?skip=0&take=250"
}

n8n_api_get_folders() {
    n8n_api_request "GET" "/folders?skip=0&take=1000"
}

n8n_api_create_folder() {
    local name="$1"
    local project_id="$2"
    local parent_id="${3:-}"

    local payload
    payload=$(jq -n \
        --arg name "$name" \
        --arg projectId "$project_id" \
        --arg parentId "${parent_id:-}" \
        '{
            name: $name,
            projectId: $projectId,
            parentFolderId: (if $parentId == "" then null else $parentId end)
        }')

    n8n_api_request "POST" "/folders" "$payload"
}

n8n_api_update_workflow_assignment() {
    local workflow_id="$1"
    local project_id="$2"
    local folder_id="${3:-}"

    local payload
    payload=$(jq -n \
        --arg projectId "$project_id" \
        --arg folderId "${folder_id:-}" \
        '{
            homeProject: {
                id: $projectId
            },
            parentFolderId: (if $folderId == "" then null else $folderId end)
        }')

    n8n_api_request "PATCH" "/workflows/$workflow_id" "$payload"
}