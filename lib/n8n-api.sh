#!/usr/bin/env bash
# =========================================================
# lib/n8n-api.sh - n8n REST API functions for n8n-manager
# =========================================================
# All functions for interacting with n8n's REST API to get
# folder structure and workflow organization data

# Source common utilities
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Authenticate with n8n and get session cookie for REST API endpoints
authenticate_n8n_session() {
    local base_url="$1"
    local email="$2"
    local password="$3"
    local cookie_file="$4"
    
    # Clean up URL
    base_url="${base_url%/}"
    
    log DEBUG "Authenticating with n8n session for REST API access"
    
    # First, get the login page to extract CSRF token if needed
    local login_response
    if ! login_response=$(curl -s -c "$cookie_file" "$base_url/signin" 2>/dev/null); then
        log ERROR "Failed to access n8n login page"
        return 1
    fi
    
    # Attempt to login and get session cookie
    local auth_response
    local http_status
    if ! auth_response=$(curl -s -w "\n%{http_code}" -b "$cookie_file" -c "$cookie_file" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$email\",\"password\":\"$password\"}" \
        "$base_url/rest/login" 2>/dev/null); then
        log ERROR "Failed to authenticate with n8n"
        return 1
    fi
    
    http_status=$(echo "$auth_response" | tail -n1)
    local response_body=$(echo "$auth_response" | head -n -1)
    
    if [[ "$http_status" == "200" ]]; then
        log DEBUG "Successfully authenticated with n8n session"
        return 0
    else
        log ERROR "n8n session authentication failed with HTTP $http_status"
        log DEBUG "Response: $response_body"
        return 1
    fi
}

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

# Comprehensive API validation - tests all available authentication methods
validate_n8n_api_access() {
    local base_url="$1"
    local api_key="$2"
    local email="${3:-}"      # Optional: for session auth fallback
    local password="${4:-}"   # Optional: for session auth fallback
    
    log INFO "🔍 Validating n8n API access and permissions..."
    
    # Clean up URL
    base_url="${base_url%/}"
    
    # If API key is blank or empty, skip API key authentication and go straight to session auth
    if [[ -n "$api_key" && "$api_key" != "" ]]; then
        log DEBUG "Testing API key authentication on /api/v1/ endpoints..."
        local api_response
        local api_status
        if api_response=$(curl -s -w "\n%{http_code}" -H "X-N8N-API-KEY: $api_key" "$base_url/api/v1/workflows?limit=1" 2>/dev/null); then
            api_status=$(echo "$api_response" | tail -n1)
            if [[ "$api_status" == "200" ]]; then
                local workflow_count
                workflow_count=$(echo "$api_response" | head -n -1 | jq -r '.data | length // 0' 2>/dev/null || echo "0")
                log SUCCESS "✅ API key authentication successful!"
                log INFO "Found $workflow_count workflows accessible via API key (/api/v1/)"
                return 0
            else
                log WARN "⚠️ API key authentication failed (HTTP $api_status), trying session auth..."
            fi
        else
            log WARN "⚠️ API key authentication request failed, trying session auth..."
        fi
    else
        log INFO "No API key provided - using session-based authentication for REST API"
    fi
    
    # Try session-based authentication for REST API endpoints
    log DEBUG "Using session authentication for /rest/ endpoints..."
    
    # If no email/password provided, prompt for them
    if [[ -z "$email" || -z "$password" ]]; then
        if [[ -n "$api_key" && "$api_key" != "" ]]; then
            log INFO "API key authentication failed. Trying session-based authentication for REST API..."
        else
            log INFO "Using session-based authentication for REST API access..."
        fi
        if [[ -z "$email" ]]; then
            printf "n8n email or LDAP login ID: "
            read -r email
        fi
        if [[ -z "$password" ]]; then
            printf "n8n password: "
            read -r -s password
            echo  # Add newline after hidden input
        fi
    fi
    
    if [[ -n "$email" && -n "$password" ]]; then
        if authenticate_n8n_session "$base_url" "$email" "$password" 3; then
            # Test the session with a simple API call
            if test_n8n_session_auth "$base_url" "$email" "$password" "true"; then
                log SUCCESS "✅ Session authentication successful!"
                log INFO "REST API endpoints are accessible via session authentication"
                return 0
            else
                log ERROR "❌ Session authentication succeeded but API test failed"
            fi
        else
            log ERROR "❌ Session authentication failed after multiple attempts"
        fi
    else
        log ERROR "❌ No valid credentials provided for session authentication"
    fi
    
    # If we get here, all authentication methods failed
    log ERROR "❌ n8n API validation failed with all available methods!"
    log ERROR "Cannot proceed without valid authentication. Please check:"
    if [[ -n "$api_key" && "$api_key" != "" ]]; then
        log ERROR "  1. API key is correct and active"
        log ERROR "  2. Try manually: curl -H \"X-N8N-API-KEY: $api_key\" \"$base_url/api/v1/workflows?limit=1\""
    fi
    if [[ -n "$email" && -n "$password" ]]; then
        log ERROR "  3. Email/LDAP login ID and password are correct"
        log ERROR "  4. n8n instance allows password authentication"
        log ERROR "  5. No additional authentication barriers (like Cloudflare Access)"
    fi
    log ERROR "  6. n8n instance is properly configured and accessible"
    log ERROR "  7. Network connectivity to n8n server"
    
    return 1
}

# Fetch all projects from n8n instance
fetch_n8n_projects() {
    local base_url="$1"
    local api_key="$2"
    
    log DEBUG "Fetching projects from n8n API..."
    
    # Clean up URL
    base_url="${base_url%/}"
    
    local response
    local http_status
    if ! response=$(curl -s -w "\\n%{http_code}" -H "X-N8N-API-KEY: $api_key" "$base_url/rest/projects" 2>/dev/null); then
        log ERROR "Failed to fetch projects from n8n API"
        return 1
    fi
    
    http_status=$(echo "$response" | tail -n1)
    local response_body=$(echo "$response" | head -n -1)
    
    if [[ "$http_status" != "200" ]]; then
        log ERROR "Failed to fetch projects (HTTP $http_status)"
        return 1
    fi
    
    echo "$response_body"
    return 0
}

# Fetch folders for a specific project
fetch_project_folders() {
    local base_url="$1"
    local api_key="$2"
    local project_id="$3"
    
    log DEBUG "Fetching folders for project: $project_id"
    
    # Clean up URL
    base_url="${base_url%/}"
    
    local response
    local http_status
    if ! response=$(curl -s -w "\\n%{http_code}" -H "X-N8N-API-KEY: $api_key" "$base_url/rest/projects/$project_id/folders" 2>/dev/null); then
        log ERROR "Failed to fetch folders for project: $project_id"
        return 1
    fi
    
    http_status=$(echo "$response" | tail -n1)
    local response_body=$(echo "$response" | head -n -1)
    
    if [[ "$http_status" != "200" ]]; then
        log ERROR "Failed to fetch project folders (HTTP $http_status)"
        return 1
    fi
    
    echo "$response_body"
    return 0
}

# Fetch workflows with folder information
fetch_workflows_with_folders() {
    local base_url="$1"
    local api_key="$2"
    local project_id="${3:-}"  # Optional project filter
    
    log DEBUG "Fetching workflows with folder information..."
    
    # Clean up URL  
    base_url="${base_url%/}"
    
    local url="$base_url/rest/workflows?includeFolders=true"
    if [[ -n "$project_id" ]]; then
        url="$url&filter[projectId]=$project_id"
    fi
    
    local response
    local http_status
    if ! response=$(curl -s -w "\\n%{http_code}" -H "X-N8N-API-KEY: $api_key" "$url" 2>/dev/null); then
        log ERROR "Failed to fetch workflows with folders"
        return 1
    fi
    
    http_status=$(echo "$response" | tail -n1)
    local response_body=$(echo "$response" | head -n -1)
    
    if [[ "$http_status" != "200" ]]; then
        log ERROR "Failed to fetch workflows (HTTP $http_status)"
        return 1
    fi
    
    echo "$response_body"
    return 0
}

# Build folder structure based on n8n's actual folder hierarchy (replaces tag-based logic)
# Create n8n folder structure mirroring the API structure
create_n8n_folder_structure() {
    local backup_dir="$1"
    
    if [[ -z "$backup_dir" ]]; then
        log "ERROR" "Backup directory not specified for folder structure creation"
        return 1
    fi
    
    log INFO "Creating folder structure based on n8n's actual folders (not tags)..."
    
    # Use runtime variables for API credentials
    local base_url="$n8n_base_url"
    local api_key="$n8n_api_key"
    local email="$n8n_email"
    local password="$n8n_password"
    
    if [[ -z "$base_url" ]]; then
        log ERROR "n8n API URL not configured. Please set N8N_BASE_URL"
        return 1
    fi
    
    # Test API connection first (non-verbose since we validated earlier)
    if ! test_n8n_api_connection "$base_url" "$api_key" "false"; then
        log ERROR "Cannot proceed with folder structure creation - API connection failed"
        return 1
    fi
    
    # Get list of workflow files from container first
    local container_workflows_dir="/home/node/.n8n/workflows"
    local workflow_files
    if ! workflow_files=$(docker exec "$container_id" find "$container_workflows_dir" -name "*.json" -type f 2>/dev/null); then
        log ERROR "Failed to get workflow files from container"
        return 1
    fi

    if [[ -z "$workflow_files" ]]; then
        log INFO "No workflow files found - clean installation"
        return 0
    fi

    # Determine authentication method and fetch API data
    local projects_response
    local workflows_response
    local using_session_auth=false
    
    # Try API key authentication first (if available)
    if [[ -n "$api_key" && "$api_key" != "" ]]; then
        log DEBUG "Trying API key authentication first..."
        if projects_response=$(fetch_n8n_projects "$base_url" "$api_key" 2>/dev/null) && \
           workflows_response=$(fetch_workflows_with_folders "$base_url" "$api_key" 2>/dev/null); then
            log SUCCESS "✅ API key authentication successful for data fetching"
            log DEBUG "Projects API response received: $(echo "$projects_response" | wc -c) characters"
            log DEBUG "Workflows API response received: $(echo "$workflows_response" | wc -c) characters"
        else
            log WARN "⚠️ API key authentication failed for REST endpoints, trying session authentication..."
            api_key=""  # Clear API key to force session auth
        fi
    else
        log INFO "No API key provided - using session authentication for REST API"
    fi
    
    # Use session authentication if API key is blank or failed
    if [[ -z "$api_key" || "$api_key" == "" ]]; then
        # Get email/password from config or prompt
        if [[ -n "$email" && -n "$password" ]]; then
            log DEBUG "Using email/password from configuration for session auth"
        else
            log INFO "Session authentication requires email/password credentials"
            if [[ -z "$email" ]]; then
                printf "n8n email or LDAP login ID: "
                read -r email
            fi
            if [[ -z "$password" ]]; then
                printf "n8n password: "
                read -r -s password
                echo  # Add newline after hidden input
            fi
        fi
        
        # Authenticate and fetch data using session
        if authenticate_n8n_session "$base_url" "$email" "$password" 3 && \
           projects_response=$(fetch_n8n_projects_session "$base_url"); then
            
            log SUCCESS "✅ Session authentication successful and projects fetched"
            log DEBUG "Raw projects response: $projects_response"
            
            # Extract project ID for workflows query
            local project_id
            project_id=$(echo "$projects_response" | jq -r '.data[0].id // ""' 2>/dev/null || echo "")
            
            log DEBUG "Extracted project ID: '$project_id'"
            
            # Fetch workflows with the project ID
            if workflows_response=$(fetch_workflows_with_folders_session "$base_url" "$project_id"); then
                log SUCCESS "✅ Successfully fetched workflows for project ID: $project_id"
                log DEBUG "Raw workflows response: $workflows_response"
                
                using_session_auth=true
            else
                log ERROR "❌ Failed to fetch workflows even after successful authentication!"
                cleanup_n8n_session
                return 1
            fi
        else
            log ERROR "❌ Session authentication failed!"
            log ERROR "Cannot proceed with folder structure creation - API authentication failed"
            log ERROR "Please check:"
            log ERROR "  1. n8n instance is running and accessible at: $base_url"
            if [[ -n "$api_key" && "$api_key" != "" ]]; then
                log ERROR "  2. API key is correct and active"
            fi
            if [[ -n "$email" && -n "$password" ]]; then
                log ERROR "  3. Email/password credentials are correct" 
                log ERROR "  4. n8n allows password authentication"
            fi
            log ERROR "  5. No authentication barriers (Cloudflare, etc.)"
            
            # Cleanup any session files
            cleanup_n8n_session
            return 1
        fi
    fi
    
    # Show sample of workflow data for debugging
    local workflow_count
    workflow_count=$(echo "$workflows_response" | jq -r '.data | length // 0' 2>/dev/null || echo "0")
    
    # Log first workflow for debugging
    if [[ "$workflow_count" -gt 0 ]]; then
        local first_workflow_info
        first_workflow_info=$(echo "$workflows_response" | jq -r '.data[0] | "First workflow: id=\(.id // "unknown"), name=\(.name // "unnamed")"' 2>/dev/null || echo "Error parsing first workflow")
        echo "$first_workflow_info" >&2
    fi
    
    echo "[DEBUG] Raw workflow count: $workflow_count"
    echo "[DEBUG] Starting workflow processing and folder structure creation..."
    log DEBUG "Found $workflow_count workflows via API"
    
    # Parse projects to create project name mapping
    local project_mapping
    project_mapping=$(echo "$projects_response" | jq -r '
        .data[]? // (if type == "array" then .[] else empty end) |
        select(.id and .name) |
        (
            .id as $id |
            .name as $name |
            .type as $type |
            if $type == "personal" then
                "\($id)|Personal"
            else
                "\($id)|\($name | gsub("/"; "_") | gsub(" "; "_"))"
            end
        )
    ' 2>/dev/null || echo "default|Personal")
    
    echo "[DEBUG] Project mapping result: $project_mapping"
    
    if [[ -z "$project_mapping" ]]; then
        log WARN "No project mapping found, using fallback structure"
        project_mapping="default|Personal"
        echo "[DEBUG] Using fallback project mapping: $project_mapping"
    fi
    
    # Track existing workflows for deletion detection
    local existing_workflows=()
    if [[ -d "$target_dir" ]]; then
        while IFS= read -r -d '' existing_file; do
            if [[ "$existing_file" =~ ([0-9]+)\.json$ ]]; then
                existing_workflows+=("${BASH_REMATCH[1]}")
            fi
        done < <(find "$target_dir" -name "*.json" -type f -print0 2>/dev/null || true)
    fi
    
    local current_workflows=()
    local new_count=0
    local updated_count=0
    
    echo "[DEBUG] Starting workflow processing - combining Docker files with API folder structure"
    echo "[DEBUG] Processing $(echo "$workflow_files" | wc -l) workflow files from Docker container"
    
    # Process each workflow file
    while IFS= read -r workflow_file; do
        if [[ -z "$workflow_file" ]]; then continue; fi
        
        echo "[DEBUG] Processing Docker workflow file: $workflow_file"
        
        # Copy workflow file to temporary location for processing
        local temp_workflow="/tmp/temp_workflow.json"
        if ! docker cp "${container_id}:${workflow_file}" "$temp_workflow" 2>/dev/null; then
            log WARN "Failed to copy workflow file: $workflow_file"
            continue
        fi
        
        # Extract basic workflow information
        local workflow_info
        if ! workflow_info=$(jq -r '(.id // "unknown") + "|" + (.name // "Unnamed Workflow")' "$temp_workflow" 2>/dev/null); then
            log WARN "Failed to parse workflow file: $workflow_file"
            rm -f "$temp_workflow"
            continue
        fi
        
        IFS='|' read -r workflow_id workflow_name <<< "$workflow_info"
        
        echo "[DEBUG] Extracted from Docker file - ID: '$workflow_id', Name: '$workflow_name'"
        
        if [[ "$workflow_id" == "ERROR" ]]; then
            log WARN "Failed to extract workflow info from: $workflow_file"
            rm -f "$temp_workflow"
            continue
        fi
        
        current_workflows+=("$workflow_id")
        
        # Find workflow's project and folder information from API response
        local folder_info
        folder_info=$(echo "$workflows_response" | jq -r --arg workflow_id "$workflow_id" '
            .data[]? // (if type == "array" then .[] else empty end) |
            select(.id == $workflow_id and .resource != "folder") |
            (
                (.homeProject.id // "default") as $project_id |
                (.parentFolderId // "") as $folder_id |
                (.parentFolder.name // "") as $folder_name |
                "\($project_id)|\($folder_id)|\($folder_name)"
            )
        ' 2>/dev/null || echo "default||")
        
        echo "[DEBUG] Workflow $workflow_id API folder info: '$folder_info'"
        
        if [[ -z "$folder_info" ]]; then
            folder_info="default||"
            echo "[DEBUG] Using fallback folder info for workflow $workflow_id"
        fi
        
        IFS='|' read -r project_id folder_id folder_name <<< "$folder_info"
        
        # Determine project folder name from mapping
        local project_folder_name="Personal"  # default
        while IFS='|' read -r mapped_project_id mapped_folder_name; do
            if [[ "$mapped_project_id" == "$project_id" ]]; then
                project_folder_name="$mapped_folder_name"
                break
            fi
        done <<< "$project_mapping"
        
        # Build the target folder path: ProjectName/[FolderName]/workflow-id.json
        local folder_path="$target_dir/$project_folder_name"
        
        echo "[DEBUG] Base folder path: '$folder_path'"
        
        if [[ -n "$folder_name" && "$folder_name" != "" ]]; then
            # Sanitize folder name (remove invalid characters)
            local clean_folder_name=$(echo "$folder_name" | tr -d '[\/:*?"<>|]' | tr ' ' '_')
            folder_path="$folder_path/$clean_folder_name"
            echo "[DEBUG] Added subfolder: '$clean_folder_name' -> Final path: '$folder_path'"
        fi
        
        # Create folder structure if it doesn't exist
        echo "[DEBUG] Creating folder structure: '$folder_path'"
        if ! mkdir -p "$folder_path"; then
            log ERROR "Failed to create folder: $folder_path"
            rm -f "$temp_workflow"
            continue
        fi
        echo "[DEBUG] Successfully created folder structure"
        
        # Determine target filename
        local target_file="$folder_path/${workflow_id}.json"
        local is_new=true
        
        echo "[DEBUG] Target file: '$target_file'"
        
        # Check if workflow already exists
        if [[ -f "$target_file" ]]; then
            is_new=false
            echo "[DEBUG] File exists, checking for changes"
            # Compare files to see if there are actual changes
            if cmp -s "$temp_workflow" "$target_file" 2>/dev/null; then
                echo "[DEBUG] Workflow $workflow_id unchanged: $workflow_name"
                log DEBUG "Workflow $workflow_id unchanged: $workflow_name"
                rm -f "$temp_workflow"
                continue
            fi
            echo "[DEBUG] File has changes, will update"
        else
            echo "[DEBUG] New file will be created"
        fi
        
        # Copy workflow to target location
        echo "[DEBUG] Copying workflow from temp to target location"
        if cp "$temp_workflow" "$target_file"; then
            if $is_new; then
                new_count=$((new_count + 1))
                echo "[DEBUG] Successfully created new workflow file"
                log SUCCESS "[New] Workflow $workflow_id: $workflow_name -> $target_file"
            else
                updated_count=$((updated_count + 1))
                echo "[DEBUG] Successfully updated existing workflow file"
                log SUCCESS "[Updated] Workflow $workflow_id: $workflow_name -> $target_file"
            fi
        else
            log ERROR "Failed to copy workflow $workflow_id to: $target_file"
            echo "[DEBUG] Failed to copy workflow file"
        fi
        
        rm -f "$temp_workflow"
        echo "[DEBUG] Cleaned up temp file, finished processing workflow $workflow_id"
        
    done <<< "$workflow_files"
    
    # Check for deleted workflows
    local deleted_count=0
    for existing_id in "${existing_workflows[@]}"; do
        local found=false
        for current_id in "${current_workflows[@]}"; do
            if [[ "$existing_id" == "$current_id" ]]; then
                found=true
                break
            fi
        done
        if ! $found; then
            # Find and remove deleted workflow files
            local deleted_files
            while IFS= read -r -d '' deleted_file; do
                if rm "$deleted_file" 2>/dev/null; then
                    deleted_count=$((deleted_count + 1))
                    log SUCCESS "[Deleted] Removed workflow file: $deleted_file"
                    
                    # Remove empty directories up the tree
                    local dir_path=$(dirname "$deleted_file")
                    while [[ "$dir_path" != "$target_dir" && "$dir_path" != "." && "$dir_path" != "/" ]]; do
                        if rmdir "$dir_path" 2>/dev/null; then
                            log DEBUG "Removed empty directory: $dir_path"
                            dir_path=$(dirname "$dir_path")
                        else
                            break
                        fi
                    done
                fi
            done < <(find "$target_dir" -name "${existing_id}.json" -type f -print0 2>/dev/null || true)
        fi
    done
    
    # Summary
    log INFO "Folder structure creation completed:"
    log INFO "  • New workflows: $new_count"
    log INFO "  • Updated workflows: $updated_count" 
    log INFO "  • Deleted workflows: $deleted_count"
    
    # DEBUG: Show the created folder structure
    echo "[DEBUG] Final folder structure created in $target_dir:"
    if [[ -d "$target_dir" ]]; then
        find "$target_dir" -type d | sort | while read -r dir; do
            local relative_path="${dir#$target_dir}"
            if [[ -n "$relative_path" ]]; then
                echo "[DEBUG]   Folder: $relative_path"
            fi
        done
        
        echo "[DEBUG] Files created in folder structure:"
        find "$target_dir" -name "*.json" | sort | while read -r file; do
            local relative_path="${file#$target_dir}"
            echo "[DEBUG]   File: $relative_path"
        done
    else
        echo "[DEBUG] Target directory does not exist: $target_dir"
    fi
    
    # Cleanup session if we used it
    if $using_session_auth; then
        cleanup_n8n_session
    fi
    
    return 0
}

# ============================================================================
# Session-based Authentication Functions for REST API (/rest/* endpoints)
# ============================================================================

# Global variable to store session cookie file path
N8N_SESSION_COOKIE_FILE="/tmp/n8n-session-cookies-$$"

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
            log SUCCESS "Successfully authenticated with n8n session!"
            
            # DEBUG: Show what cookies we got
            if [[ -f "$N8N_SESSION_COOKIE_FILE" ]]; then
                echo "[DEBUG] Cookie file contents:"
                cat "$N8N_SESSION_COOKIE_FILE"
                echo "[DEBUG] End cookie file contents"
            else
                echo "[DEBUG] No cookie file found at: $N8N_SESSION_COOKIE_FILE"
            fi
            
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
        echo "[DEBUG] Projects API Response Body: $response_body"
        return 1
    fi
    
    echo "[DEBUG] Projects API Success - Response: $response_body"
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
        echo "[DEBUG] Workflows API Response Body: $response_body"
        echo "[DEBUG] Query URL was: $query_url"
        return 1
    fi
    
    echo "[DEBUG] Workflows API Success - Response: $response_body"
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