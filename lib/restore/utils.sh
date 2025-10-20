
# shellcheck disable=SC2034

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
