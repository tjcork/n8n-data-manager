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
    local email="$3"      # Optional: for session auth fallback
    local password="$4"   # Optional: for session auth fallback
    
    log INFO "🔍 Validating n8n API access and permissions..."
    
    # Clean up URL
    base_url="${base_url%/}"
    
    # First try API key authentication with /api/v1/ endpoint
    if [[ -n "$api_key" ]]; then
        log DEBUG "Testing API key authentication on /api/v1/ endpoints..."
        local api_response
        local api_status
        if api_response=$(curl -s -w "\n%{http_code}" -H "X-N8N-API-KEY: $api_key" "$base_url/api/v1/workflows?limit=1" 2>/dev/null); then
            api_status=$(echo "$api_response" | tail -n1)
            if [[ "$api_status" == "200" ]]; then
                local workflow_count
                workflow_count=$(echo "$api_response" | head -n -1 | python3 -c "
import json
import sys
try:
    data = json.load(sys.stdin)
    if isinstance(data, dict) and 'data' in data:
        print(len(data['data']))
    else:
        print('0')
except:
    print('0')
" 2>/dev/null)
                log SUCCESS "✅ API key authentication successful!"
                log INFO "Found $workflow_count workflows accessible via API key (/api/v1/)"
                return 0
            else
                log WARN "⚠️ API key authentication failed (HTTP $api_status)"
            fi
        else
            log WARN "⚠️ API key authentication request failed"
        fi
    fi
    
    # If API key failed, try session authentication for REST API endpoints
    log DEBUG "Trying session authentication for /rest/ endpoints..."
    
    # If no email/password provided, prompt for them
    if [[ -z "$email" || -z "$password" ]]; then
        log INFO "API key authentication failed. Trying session-based authentication for REST API..."
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
        if test_n8n_session_auth "$base_url" "$email" "$password" "true"; then
            log SUCCESS "✅ Session authentication successful!"
            log INFO "REST API endpoints are accessible via session authentication"
            return 0
        else
            log ERROR "❌ Session authentication also failed"
        fi
    fi
    
    # If we get here, all authentication methods failed
    log ERROR "❌ n8n API validation failed with all available methods!"
    log ERROR "Please check:"
    if [[ -n "$api_key" ]]; then
        log ERROR "  1. API key is correct and active"
        log ERROR "  2. Try /api/v1/ endpoints: curl -H \"X-N8N-API-KEY: $api_key\" \"$base_url/api/v1/workflows?limit=1\""
    fi
    if [[ -n "$email" && -n "$password" ]]; then
        log ERROR "  3. Email/LDAP login ID and password are correct"
        log ERROR "  4. n8n instance allows password authentication"
    fi
    log ERROR "  5. n8n instance is properly configured and accessible"
    
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
    
    # Use global variables for API credentials
    local base_url="$CONF_N8N_BASE_URL"
    local api_key="$CONF_N8N_API_KEY"
    
    if [[ -z "$base_url" ]] || [[ -z "$api_key" ]]; then
        log ERROR "n8n API credentials not configured. Please set CONF_N8N_BASE_URL and CONF_N8N_API_KEY"
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
    
    # Fetch projects and workflows with folder information from API
    local projects_response
    local workflows_response
    local using_session_auth=false
    
    # First try API key authentication
    if projects_response=$(fetch_n8n_projects "$base_url" "$api_key" 2>/dev/null) && \
       workflows_response=$(fetch_workflows_with_folders "$base_url" "$api_key" 2>/dev/null); then
        log DEBUG "Successfully fetched data using API key authentication"
        log DEBUG "Projects API response received: $(echo "$projects_response" | wc -c) characters"
        log DEBUG "Workflows API response received: $(echo "$workflows_response" | wc -c) characters"
    else
        log WARN "API key authentication failed for REST endpoints, trying session authentication..."
        
        # Try to get email/password for session auth
        local email password
        if [[ -n "$CONF_N8N_EMAIL" && -n "$CONF_N8N_PASSWORD" ]]; then
            email="$CONF_N8N_EMAIL"
            password="$CONF_N8N_PASSWORD"
        else
            log INFO "Session authentication requires email/password credentials"
            printf "n8n email or LDAP login ID: "
            read -r email
            printf "n8n password: "
            read -r -s password
            echo  # Add newline after hidden input
        fi
        
        # Authenticate and fetch data using session
        if authenticate_n8n_session "$base_url" "$email" "$password" && \
           projects_response=$(fetch_n8n_projects_session "$base_url" 2>/dev/null) && \
           workflows_response=$(fetch_workflows_with_folders_session "$base_url" 2>/dev/null); then
            log SUCCESS "Successfully fetched data using session authentication"
            log DEBUG "Projects session response received: $(echo "$projects_response" | wc -c) characters"
            log DEBUG "Workflows session response received: $(echo "$workflows_response" | wc -c) characters"
            using_session_auth=true
        else
            log ERROR "Both API key and session authentication failed"
            log ERROR "Cannot proceed with folder structure creation"
            return 1
        fi
    fi
    
    # Show sample of workflow data for debugging
    local workflow_count
    workflow_count=$(echo "$workflows_response" | python3 -c "
import json
import sys
try:
    data = json.load(sys.stdin)
    if isinstance(data, dict) and 'data' in data:
        workflows = data['data']
        print(len(workflows))
        if workflows:
            print(f'First workflow: id={workflows[0].get(\"id\", \"unknown\")}, name={workflows[0].get(\"name\", \"unnamed\")}', file=sys.stderr)
    else:
        print('0')
except Exception as e:
    print(f'Error parsing workflows: {e}', file=sys.stderr)
    print('0')
" 2>&1)
    log DEBUG "Found $workflow_count workflows via API"
    
    # Parse projects to create project name mapping
    local project_mapping
    project_mapping=$(echo "$projects_response" | python3 -c "
import json
import sys
try:
    data = json.load(sys.stdin)
    for project in data.get('data', data if isinstance(data, list) else []):
        project_id = project.get('id', '')
        project_name = project.get('name', 'Unknown')
        project_type = project.get('type', 'team')
        # Create clean project folder name
        if project_type == 'personal':
            folder_name = 'Personal'
        else:
            # Sanitize project name for folder use
            folder_name = project_name.replace('/', '_').replace(' ', '_')
        print(f'{project_id}|{folder_name}')
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)
    
    if [[ -z "$project_mapping" ]]; then
        log WARN "No project mapping found, using fallback structure"
        project_mapping="default|Personal"
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
    
    # Process each workflow file
    while IFS= read -r workflow_file; do
        if [[ -z "$workflow_file" ]]; then continue; fi
        
        # Copy workflow file to temporary location for processing
        local temp_workflow="/tmp/temp_workflow.json"
        if ! docker cp "${container_id}:${workflow_file}" "$temp_workflow" 2>/dev/null; then
            log WARN "Failed to copy workflow file: $workflow_file"
            continue
        fi
        
        # Extract basic workflow information
        local workflow_info
        if ! workflow_info=$(python3 -c "
import json
import sys
try:
    with open('$temp_workflow', 'r') as f:
        data = json.load(f)
    workflow_id = data.get('id', 'unknown')
    workflow_name = data.get('name', 'Unnamed Workflow')
    print(f'{workflow_id}|{workflow_name}')
except Exception as e:
    print('ERROR|ERROR')
    sys.exit(1)
" 2>/dev/null); then
            log WARN "Failed to parse workflow file: $workflow_file"
            rm -f "$temp_workflow"
            continue
        fi
        
        IFS='|' read -r workflow_id workflow_name <<< "$workflow_info"
        
        if [[ "$workflow_id" == "ERROR" ]]; then
            log WARN "Failed to extract workflow info from: $workflow_file"
            rm -f "$temp_workflow"
            continue
        fi
        
        current_workflows+=("$workflow_id")
        
        # Find workflow's project and folder information from API response
        local folder_info
        folder_info=$(echo "$workflows_response" | python3 -c "
import json
import sys
try:
    data = json.load(sys.stdin)
    workflows = data.get('data', data if isinstance(data, list) else [])
    for workflow in workflows:
        if workflow.get('id') == '$workflow_id':
            project_id = workflow.get('projectId', 'default')
            folder_id = workflow.get('folderId', None)
            folder_name = workflow.get('folderName', None)
            print(f'{project_id}|{folder_id or \"\"}|{folder_name or \"\"}')
            break
    else:
        # Workflow not found in API response, use default
        print('default||')
except Exception as e:
    print('default||')
" 2>/dev/null)
        
        if [[ -z "$folder_info" ]]; then
            folder_info="default||"
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
        
        if [[ -n "$folder_name" && "$folder_name" != "" ]]; then
            # Sanitize folder name (remove invalid characters)
            local clean_folder_name=$(echo "$folder_name" | tr -d '[\/:*?"<>|]' | tr ' ' '_')
            folder_path="$folder_path/$clean_folder_name"
        fi
        
        # Create folder structure if it doesn't exist
        if ! mkdir -p "$folder_path"; then
            log ERROR "Failed to create folder: $folder_path"
            rm -f "$temp_workflow"
            continue
        fi
        
        # Determine target filename
        local target_file="$folder_path/${workflow_id}.json"
        local is_new=true
        
        # Check if workflow already exists
        if [[ -f "$target_file" ]]; then
            is_new=false
            # Compare files to see if there are actual changes
            if cmp -s "$temp_workflow" "$target_file" 2>/dev/null; then
                log DEBUG "Workflow $workflow_id unchanged: $workflow_name"
                rm -f "$temp_workflow"
                continue
            fi
        fi
        
        # Copy workflow to target location
        if cp "$temp_workflow" "$target_file"; then
            if $is_new; then
                new_count=$((new_count + 1))
                log SUCCESS "[New] Workflow $workflow_id: $workflow_name -> $target_file"
            else
                updated_count=$((updated_count + 1))
                log SUCCESS "[Updated] Workflow $workflow_id: $workflow_name -> $target_file"
            fi
        else
            log ERROR "Failed to copy workflow $workflow_id to: $target_file"
        fi
        
        rm -f "$temp_workflow"
        
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
    
    # Clean up URL
    base_url="${base_url%/}"
    
    log DEBUG "Authenticating with n8n session for REST API access"
    
    # Attempt to login and get session cookie
    local auth_response
    local http_status
    if ! auth_response=$(curl -s -w "\n%{http_code}" -c "$N8N_SESSION_COOKIE_FILE" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "{\"body\":{\"emailOrLdapLoginId\":\"$email\",\"password\":\"$password\"}}" \
        "$base_url/rest/login" 2>/dev/null); then
        log ERROR "Failed to authenticate with n8n session"
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

# Fetch projects using session authentication (REST API)
fetch_n8n_projects_session() {
    local base_url="$1"
    
    log DEBUG "Fetching projects from n8n REST API using session..."
    
    # Clean up URL
    base_url="${base_url%/}"
    
    local response
    local http_status
    if ! response=$(curl -s -w "\n%{http_code}" -b "$N8N_SESSION_COOKIE_FILE" "$base_url/rest/projects" 2>/dev/null); then
        log ERROR "Failed to fetch projects from n8n REST API"
        return 1
    fi
    
    http_status=$(echo "$response" | tail -n1)
    local response_body=$(echo "$response" | head -n -1)
    
    if [[ "$http_status" != "200" ]]; then
        log ERROR "Failed to fetch projects via session (HTTP $http_status)"
        return 1
    fi
    
    echo "$response_body"
    return 0
}

# Fetch workflows with folders using session authentication (REST API)
fetch_workflows_with_folders_session() {
    local base_url="$1"
    
    log DEBUG "Fetching workflows with folders from n8n REST API using session..."
    
    # Clean up URL
    base_url="${base_url%/}"
    
    local response
    local http_status
    if ! response=$(curl -s -w "\n%{http_code}" -b "$N8N_SESSION_COOKIE_FILE" "$base_url/rest/workflows?includeFolders=true" 2>/dev/null); then
        log ERROR "Failed to fetch workflows from n8n REST API"
        return 1
    fi
    
    http_status=$(echo "$response" | tail -n1)
    local response_body=$(echo "$response" | head -n -1)
    
    if [[ "$http_status" != "200" ]]; then
        log ERROR "Failed to fetch workflows with folders via session (HTTP $http_status)"
        return 1
    fi
    
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
            workflow_count=$(echo "$response_body" | python3 -c "
import json
import sys
try:
    data = json.load(sys.stdin)
    if isinstance(data, dict) and 'data' in data:
        print(len(data['data']))
    else:
        print('0')
except:
    print('0')
" 2>/dev/null)
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