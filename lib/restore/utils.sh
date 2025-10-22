
# shellcheck disable=SC2034

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

capture_existing_workflow_snapshot() {
    local container_id="$1"
    local keep_session_alive="${2:-false}"
    local existing_path="${3:-}"
    local is_dry_run="${4:-false}"
    local result_ref="${5:-}"

    local result="$existing_path"
    local status=0

    if [[ "$is_dry_run" == "true" ]]; then
        status=0
    elif [[ -n "$existing_path" && -f "$existing_path" ]]; then
        status=0
    else
        SNAPSHOT_EXISTING_WORKFLOWS_PATH=""
        if snapshot_existing_workflows "$container_id" "" "$keep_session_alive"; then
            result="$SNAPSHOT_EXISTING_WORKFLOWS_PATH"
            status=0
        else
            result=""
            status=1
        fi
    fi

    if [[ -n "$result_ref" ]]; then
        printf -v "$result_ref" '%s' "$result"
    else
        printf '%s' "$result"
    fi

    return "$status"
}

find_workflow_directory() {
    local candidate
    for candidate in "$@"; do
        if [[ -z "$candidate" || ! -d "$candidate" ]]; then
            continue
        fi
        if find "$candidate" -type f -name "*.json" \
            ! -path "*/.credentials/*" \
            ! -path "*/archive/*" \
            ! -name "credentials.json" \
            ! -name "workflows.json" \
            -print -quit >/dev/null 2>&1; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

locate_workflow_artifacts() {
    local base_dir="$1"
    local repo_root="$2"
    local storage_relative="$3"
    local result_workflows_ref="$4"
    local result_directory_ref="$5"

    local -n __workflows_out="$result_workflows_ref"
    local -n __directory_out="$result_directory_ref"

    __workflows_out=""
    __directory_out=""

    if [[ -n "$base_dir" && -f "$base_dir/workflows.json" ]]; then
        __workflows_out="$base_dir/workflows.json"
    elif [[ -n "$repo_root" && -f "$repo_root/workflows.json" ]]; then
        __workflows_out="$repo_root/workflows.json"
    fi

    local -a structure_candidates=()
    if [[ -n "$storage_relative" ]]; then
        structure_candidates+=("$base_dir/$storage_relative")
        if [[ -n "$repo_root" ]]; then
            structure_candidates+=("$repo_root/$storage_relative")
        fi
    fi
    structure_candidates+=("$base_dir")
    if [[ -n "$repo_root" ]]; then
        structure_candidates+=("$repo_root")
    fi

    local detected_dir
    if detected_dir=$(find_workflow_directory "${structure_candidates[@]}"); then
        __directory_out="$detected_dir"
    fi
}

locate_credentials_artifact() {
    local base_dir="$1"
    local repo_root="$2"
    local credentials_subpath="$3"
    local result_ref="$4"

    local -n __credentials_out="$result_ref"
    __credentials_out=""

    local -a candidates=()
    if [[ -n "$credentials_subpath" ]]; then
        candidates+=("$base_dir/$credentials_subpath")
        if [[ -n "$repo_root" ]]; then
            candidates+=("$repo_root/$credentials_subpath")
        fi
    fi

    local candidate
    for candidate in "${candidates[@]}"; do
        if [[ -n "$candidate" && -f "$candidate" ]]; then
            __credentials_out="$candidate"
            return 0
        fi
    done

    return 1
}

persist_manifest_debug_copy() {
    local source_path="$1"
    local target_path="$2"
    local description="${3:-manifest}"

    if [[ -z "$target_path" || -z "$source_path" || ! -f "$source_path" ]]; then
        return 0
    fi

    if cp "$source_path" "$target_path" 2>/dev/null; then
        log DEBUG "Persisted ${description} to $target_path"
    else
        log DEBUG "Unable to persist ${description} to $target_path"
    fi
    return 0
}

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
