###############################################################################
# Anthropic multi-config env manager (+ interactive `claude` helper)
# - Stores configs in: ${XDG_CONFIG_HOME:-$HOME/.config}/anthropic-env/configs.sh
# - Exports per-config: ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_API_KEY,
#   ANTHROPIC_MODEL, ANTHROPIC_SMALL_FAST_MODEL
###############################################################################

# Where configs live (persisted between shells)
AE_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/anthropic-env"
AE_CONFIG_FILE="${AE_CONFIG_DIR}/configs.sh"
mkdir -p "$AE_CONFIG_DIR"

# Ensure array exists even if no file yet
declare -a AE_CONFIGS

# Load persisted configs if present
if [[ -f "$AE_CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$AE_CONFIG_FILE"
fi

# --- Helpers to manipulate configs (Bash 3 compatible) ---

# Sanitize a human name to a slug (lowercase, alnum + dash)
anthropic_slugify() {
  # usage: anthropic_slugify "My Name" -> "my-name"
  local s="$*"
  s=$(printf '%s' "$s" | sed -E 's/[^a-zA-Z0-9]+/-/g' | sed -E 's/^-+|-+$//g' | tr '[:upper:]' '[:lower:]')
  printf '%s' "${s:-cfg}"
}

# Convert slug -> VAR chunk (uppercase + underscores) for variable names
anthropic_slug_to_var() {
  local s="$1"
  s=$(printf '%s' "$s" | sed 's/[^A-Za-z0-9]/_/g' | tr '[:lower:]' '[:upper:]')
  printf '%s' "$s"
}

# Get config field for slug (returns empty if not set)
# fields: BASE_URL, AUTH_TOKEN, MODEL, SMALL_FAST_MODEL
anthropic_cfg_get() {
  local slug="$1" field="$2"
  local up; up=$(anthropic_slug_to_var "$slug")
  local var="AE_CFG_${up}_${field}"
  printf '%s' "${!var-}"
}

# Persist a config block (append to AE_CONFIG_FILE)
anthropic_cfg_save() {
  local slug="$1" base_url="$2" token="$3" model="$4" small="$5"
  local up; up=$(anthropic_slug_to_var "$slug")

  # Create file with restricted perms if new
  if [[ ! -f "$AE_CONFIG_FILE" ]]; then
    : > "$AE_CONFIG_FILE"
    chmod 600 "$AE_CONFIG_FILE" 2>/dev/null || true
  fi

  # Use %q for safe shell quoting
  {
    printf 'AE_CONFIGS+=(%q)\n' "$slug"
    printf 'AE_CFG_%s_BASE_URL=%q\n' "$up" "$base_url"
    printf 'AE_CFG_%s_AUTH_TOKEN=%q\n' "$up" "$token"
    printf 'AE_CFG_%s_MODEL=%q\n' "$up" "$model"
    printf 'AE_CFG_%s_SMALL_FAST_MODEL=%q\n' "$up" "$small"
    printf '\n'
  } >> "$AE_CONFIG_FILE"
}

# List configs
anthropic_list_configs() {
  local i slug url model small
  if [[ ${#AE_CONFIGS[@]} -eq 0 ]]; then
    echo "No Anthropic configs found. Add one with: claude add"
    return 0
  fi
  for ((i=0; i<${#AE_CONFIGS[@]}; i++)); do
    slug="${AE_CONFIGS[$i]}"
    url=$(anthropic_cfg_get "$slug" BASE_URL)
    model=$(anthropic_cfg_get "$slug" MODEL)
    small=$(anthropic_cfg_get "$slug" SMALL_FAST_MODEL)
    printf '%2d) %-20s  URL=%s\n' "$((i+1))" "$slug" "${url:-[none]}"
    printf '    MODEL=%s  SMALL=%s\n' "${model:-[empty]}" "${small:-[empty]}"
  done
}

# Resolve an identifier (index or slug) to slug
anthropic_resolve_slug() {
  local id="$1"
  if [[ "$id" =~ ^[0-9]+$ ]]; then
    local idx=$((id-1))
    if (( idx >= 0 && idx < ${#AE_CONFIGS[@]} )); then
      printf '%s' "${AE_CONFIGS[$idx]}"
      return 0
    fi
    return 1
  fi
  # treat as slug/name (normalize like slugify but keep provided hyphens/underscores)
  local s; s=$(anthropic_slugify "$id")
  # must exist
  local i
  for ((i=0; i<${#AE_CONFIGS[@]}; i++)); do
    if [[ "${AE_CONFIGS[$i]}" == "$s" ]]; then
      printf '%s' "$s"
      return 0
    fi
  done
  return 1
}

# Apply a config by slug or index
anthropic_apply_config() {
  local id="$1" slug
  if [[ -z "$id" ]]; then
    echo "anthropic_apply_config: missing config id" >&2
    return 1
  fi
  if ! slug=$(anthropic_resolve_slug "$id"); then
    echo "Unknown config: $id" >&2
    return 1
  fi
  local url token model small
  url=$(anthropic_cfg_get "$slug" BASE_URL)
  token=$(anthropic_cfg_get "$slug" AUTH_TOKEN)
  model=$(anthropic_cfg_get "$slug" MODEL)
  small=$(anthropic_cfg_get "$slug" SMALL_FAST_MODEL)

  # Export canonical env vars (empty if not set)
  export ANTHROPIC_BASE_URL="${url:-}"
  export ANTHROPIC_AUTH_TOKEN="${token:-}"
  export ANTHROPIC_API_KEY="${ANTHROPIC_AUTH_TOKEN}"   # alias for compatibility
  export ANTHROPIC_MODEL="${model:-}"
  export ANTHROPIC_SMALL_FAST_MODEL="${small:-}"

  # Track active config (both slug + index for convenience)
  export ANTHROPIC_ACTIVE_CONFIG_SLUG="$slug"
  local i
  for ((i=0; i<${#AE_CONFIGS[@]}; i++)); do
    if [[ "${AE_CONFIGS[$i]}" == "$slug" ]]; then
      export ANTHROPIC_ACTIVE_CONFIG_INDEX="$((i+1))"
      export ANTHROPIC_ACTIVE_CONFIG="$ANTHROPIC_ACTIVE_CONFIG_INDEX" # backward compat
      break
    fi
  done
}

anthropic_print_current() {
  if [[ -z "${ANTHROPIC_ACTIVE_CONFIG_SLUG:-}" ]]; then
    echo "No active Anthropic config."
    return 0
  fi
  echo "Active Anthropic config: ${ANTHROPIC_ACTIVE_CONFIG_INDEX:-?}) ${ANTHROPIC_ACTIVE_CONFIG_SLUG}"
  echo "  ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL"
  echo "  ANTHROPIC_MODEL=${ANTHROPIC_MODEL:-[empty]}"
  echo "  ANTHROPIC_SMALL_FAST_MODEL=${ANTHROPIC_SMALL_FAST_MODEL:-[empty]}"
  echo "  ANTHROPIC_AUTH_TOKEN=[HIDDEN]"
}

# Add a new config interactively
anthropic_add_config() {
  echo "Add a new Anthropic configuration"
  local token url model small name slug default_name host

  # Ask for token (hidden input)
  read -rsp "Enter auth token (will be stored in $AE_CONFIG_FILE): " token
  echo
  if [[ -z "$token" ]]; then
    echo "Aborted: empty token."
    return 1
  fi

  # URL
  read -rp "Enter base URL (e.g., https://api.anthropic.com or your proxy): " url
  if [[ -z "$url" ]]; then
    echo "Aborted: empty base URL."
    return 1
  fi

  # Derive default name from host
  host="${url#*://}"; host="${host%%/*}"
  default_name=$(anthropic_slugify "$host")

  # Optional config display name
  read -rp "Enter a short name for this config [${default_name}]: " name
  name="${name:-$default_name}"
  slug=$(anthropic_slugify "$name")

  # Ensure unique slug
  local unique="$slug" n=2 found
  while :; do
    found=0
    for s in "${AE_CONFIGS[@]}"; do
      if [[ "$s" == "$unique" ]]; then found=1; break; fi
    done
    [[ $found -eq 0 ]] && break
    unique="${slug}-${n}"
    n=$((n+1))
  done
  slug="$unique"

  # Optional model names
  read -rp "Default model (optional, leave blank): " model
  read -rp "Small/fast model (optional, leave blank): " small

  # Persist
  anthropic_cfg_save "$slug" "$url" "$token" "$model" "$small"
  # Make it available immediately in this shell
  AE_CONFIGS+=("$slug")

  echo "Saved config '$slug'."
  anthropic_apply_config "$slug"
  anthropic_print_current
}

# If there is at least one config, apply a default automatically on shell startup.
# Priority:
#  1) ANTHROPIC_ACTIVE_CONFIG set by user (index or slug)
#  2) AE_DEFAULT (index or slug)
#  3) first config in AE_CONFIGS
if [[ -z "${ANTHROPIC_ACTIVE_CONFIG_SLUG:-}" && ${#AE_CONFIGS[@]} -gt 0 ]]; then
  if [[ -n "${ANTHROPIC_ACTIVE_CONFIG:-}" ]]; then
    anthropic_apply_config "${ANTHROPIC_ACTIVE_CONFIG}" || anthropic_apply_config "1"
  elif [[ -n "${AE_DEFAULT:-}" ]]; then
    anthropic_apply_config "${AE_DEFAULT}" || anthropic_apply_config "1"
  else
    anthropic_apply_config "1"
  fi
fi

# The `claude` function: manage configs and optionally run a `claude` binary if present
claude() {
  local _claude_bin
  _claude_bin="$(type -P claude || true)"

  case "$1" in
    ls|list)
      anthropic_list_configs
      return 0
      ;;
    current|show)
      anthropic_print_current
      return 0
      ;;
    use|switch)
      shift
      local id="$1"
      if [[ -z "$id" ]]; then
        echo "Usage: claude use <index|name>"
        anthropic_list_configs
        return 1
      fi
      if anthropic_apply_config "$id"; then
        export ANTHROPIC_CONFIG_CONFIRMED=1
        anthropic_print_current
        return 0
      else
        return 1
      fi
      ;;
    add|new)
      anthropic_add_config
      return $?
      ;;
    edit)
      "${EDITOR:-vi}" "$AE_CONFIG_FILE"
      # Reload after editing
      # shellcheck disable=SC1090
      source "$AE_CONFIG_FILE"
      echo "Reloaded configs."
      return 0
      ;;
  esac

  # First-ever `claude` in this shell? If no active config, prompt to choose.
  if [[ -z "${ANTHROPIC_CONFIG_CONFIRMED:-}" ]]; then
    if [[ ${#AE_CONFIGS[@]} -eq 0 ]]; then
      echo "No configs found. Let's create one."
      anthropic_add_config || return $?
      export ANTHROPIC_CONFIG_CONFIRMED=1
    else
      echo "Select Anthropic config:"
      anthropic_list_configs
      local _choice
      read -rp "Enter index or name [${ANTHROPIC_ACTIVE_CONFIG_INDEX:-1}]: " _choice
      _choice="${_choice:-${ANTHROPIC_ACTIVE_CONFIG_INDEX:-1}}"
      anthropic_apply_config "$_choice" || return $?
      export ANTHROPIC_CONFIG_CONFIRMED=1
    fi
  fi

  # If a real `claude` binary exists, run it; otherwise just report env.
  if [[ -n "$_claude_bin" ]]; then
    "$_claude_bin" "$@"
  else
    echo "Note: no 'claude' CLI found in PATH. Environment is set:"
    anthropic_print_current
  fi
}
