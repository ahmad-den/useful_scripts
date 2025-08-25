#!/bin/bash
# WordPress → Perfmatters Configuration Generator
# Author: Ahmad Sami
# Usage: ./wp-perfmatters-generator.sh [wordpress-path] [api-url] [--use-child]
set -euo pipefail

# --- basic knobs ---
WORDPRESS_PATH="${1:-$(pwd)}"
API_URL="${2:-https://perfmatters.checkmysite.app}"

# wp-cli flags we can safely use while “reading” things
WPARGS_COMMON="--allow-root --skip-plugins --skip-themes"

OUTPUT_DIR="perfmatters-configs"
TIMESTAMP="$(date +"%Y%m%d_%H%M%S")"

# curl shouldn’t hang forever
CURL_OPTS=(--connect-timeout 5 --max-time 25 --retry 2 --retry-delay 1 -sS)

# tiny color logger (nothing fancy)
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" >&2; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1" >&2; }

show_usage() {
  cat >&2 <<EOF
WordPress → Perfmatters Configuration Generator

Usage:
  $0 [wordpress-path] [api-url] [--use-child]

Notes:
  - By default, "primary" theme is the PARENT (template).
  - Pass --use-child (or PM_USE_CHILD=1) to make CHILD the primary.
  - Both parent+child are always sent to the backend.

Requires: jq, wp-cli, curl
EOF
}

check_jq() {
  command -v jq >/dev/null 2>&1 || { error "jq is required."; exit 1; }
}

check_wp_cli() {
  command -v wp >/dev/null 2>&1 || { error "WP-CLI not found (https://wp-cli.org/#installing)"; exit 1; }
  log "WP-CLI: $(wp --version $WPARGS_COMMON 2>&1 | tr '\n' ' ')"
}

check_wordpress() {
  cd "$WORDPRESS_PATH" || { error "Cannot access: $WORDPRESS_PATH"; exit 1; }
  if ! wp core is-installed $WPARGS_COMMON >/dev/null 2>&1; then
    error "WordPress not installed / not accessible here."
    exit 1
  fi
  local wp_version site_url
  wp_version="$(wp core version $WPARGS_COMMON 2>/dev/null || echo "unknown")"
  site_url="$(wp option get siteurl $WPARGS_COMMON 2>/dev/null || echo "")"
  log "WordPress v${wp_version} — ${site_url}"
}

# active plugin slugs as a JSON array
get_plugins_json_array() {
  log "Reading active plugins…"
  local plugins_json
  plugins_json="$(wp plugin list --status=active --format=json $WPARGS_COMMON 2>/dev/null || echo "[]")"
  if [[ -z "$plugins_json" || "$plugins_json" == "[]" ]]; then
    warning "No active plugins found."
    echo "[]"; return
  fi
  echo "$plugins_json" | jq -r '.[] | "  - \(.name) (v\(.version))"' >&2 || true
  echo "$plugins_json" | jq -c '[.[].name]'
}

# get both parent and child; “primary” is parent unless --use-child
get_theme_slugs_json() {
  log "Figuring out active theme…"
  local use_child="${PM_USE_CHILD:-0}"
  for a in "$@"; do
    [[ "$a" == "--use-child" ]] && use_child=1
  done

  local active_json
  active_json="$(wp theme list --status=active --format=json $WPARGS_COMMON 2>/dev/null || echo "[]")"
  if [[ -z "$active_json" || "$active_json" == "[]" ]]; then
    error "No active theme found."
    printf '%s\n' '{"parent":"default","child":"default","primary":"default","themes":["default"]}'
    return
  fi

  local child_slug parent_slug
  child_slug="$(echo "$active_json" | jq -r '.[0].name // empty')"
  if [[ -z "$child_slug" ]]; then
    error "Could not parse active theme."
    printf '%s\n' '{"parent":"default","child":"default","primary":"default","themes":["default"]}'
    return
  fi

  parent_slug="$(wp theme get "$child_slug" --field=template $WPARGS_COMMON 2>/dev/null || true)"
  [[ -z "$parent_slug" || "$parent_slug" == "null" ]] && parent_slug="$child_slug"

  wp theme get "$child_slug"  --field=title $WPARGS_COMMON 2>/dev/null | xargs -I{} echo "Active: {} (slug: $child_slug)" >&2 || true
  if [[ "$parent_slug" != "$child_slug" ]]; then
    wp theme get "$parent_slug" --field=title $WPARGS_COMMON 2>/dev/null | xargs -I{} echo "Parent: {} (slug: $parent_slug)" >&2 || true
  fi

  local primary="$parent_slug"
  if [[ "$use_child" == "1" ]]; then
    primary="$child_slug"
    log "Primary set to CHILD (by request)."
  else
    log "Primary is PARENT (default)."
  fi

  jq -n --arg parent "$parent_slug" --arg child "$child_slug" --arg primary "$primary" '
    { parent: $parent
    , child:  $child
    , primary: $primary
    , themes: ( [$parent, $child] | unique )
    }'
}

get_domain_json() {
  log "Grabbing site URL…"
  local site_url
  site_url="$(wp option get siteurl $WPARGS_COMMON 2>/dev/null || echo "")"
  if [[ -z "$site_url" ]]; then
    error "Could not fetch site URL."
    printf '%s\n' '"https://example.com"'; return
  fi
  log "Site: $site_url"
  jq -Rn --arg s "$site_url" '$s'
}

test_api() {
  log "Checking API…"
  local health code body
  health="$(curl "${CURL_OPTS[@]}" -w '\n%{http_code}' "$API_URL/health" || true)"
  code="$(echo "$health" | tail -n1)"
  body="$(echo "$health"  | head -n -1)"
  if [[ "$code" == "200" ]]; then
    success "API is up."
    echo "$body" | jq -r '"  Status: " + (.status // "unknown") + "\n  Version: " + (.version // "unknown")' >&2 || true
    return 0
  fi
  error "API not reachable (HTTP $code)"
  error "URL: $API_URL/health"
  error "Resp: $body"
  return 1
}

generate_config() {
  local plugins_json="$1" theme_json="$2" domain_json="$3"
  log "Building config…"
  mkdir -p "$OUTPUT_DIR"

  # unpack bits we need for the payload
  local domain_str theme_primary theme_parent theme_child themes_arr
  domain_str="$(jq -r '.' <<<"$domain_json")"
  theme_primary="$(echo "$theme_json" | jq -r '.primary')"
  theme_parent="$(echo "$theme_json" | jq -r '.parent')"
  theme_child="$(echo "$theme_json"  | jq -r '.child')"
  themes_arr="$(echo "$theme_json"   | jq -c '.themes')"

  local json_payload
  json_payload="$(jq -n \
    --argjson plugins "$plugins_json" \
    --arg domain "$domain_str" \
    --arg theme "$theme_primary" \
    --arg theme_parent "$theme_parent" \
    --arg theme_child "$theme_child" \
    --argjson themes "$themes_arr" \
    '{
       plugins: $plugins,
       domain:  $domain,
       analyze_domain: true,
       # legacy single field (kept for back-compat)
       theme: $theme,
       # new fields (explicit parent/child + the list)
       theme_parent: $theme_parent,
       theme_child:  $theme_child,
       themes: $themes
     }'
  )"

  echo "$json_payload" | jq . >/dev/null

  log "POST /generate-config payload:"
  echo "$json_payload" | jq . >&2

  local outfile="$OUTPUT_DIR/perfmatters-config-$TIMESTAMP.json"
  local resp code body
  resp="$(curl "${CURL_OPTS[@]}" -w '\n%{http_code}' \
          -X POST -H 'Content-Type: application/json' \
          -H 'User-Agent: WordPress-Perfmatters-Generator/1.4' \
          -d "$json_payload" "$API_URL/generate-config" || true)"
  code="$(echo "$resp" | tail -n1)"
  body="$(echo "$resp" | head -n -1)"

  if [[ "$code" == "200" ]]; then
    echo "$body" > "$outfile"
    success "Config saved → $outfile"
    echo "$body" | jq -r '
      if .processing_info then
        "  Plugins processed: " + ((.processing_info.plugins_processed // 0)|tostring) +
        "\n  Theme processed: "   + ((.processing_info.theme_processed // 0)|tostring) +
        "\n  Generated at: "      + (.generated_at // "unknown")
      else
        "  (No processing_info provided)"
      end
    ' >&2 || true
    return 0
  fi

  error "API said $code"
  error "Body: $body"
  local errf="$OUTPUT_DIR/error-$TIMESTAMP.json"
  echo "$body" > "$errf"
  warning "Saved error payload: $errf"
  return 1
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_usage; exit 0
  fi

  echo "🚀 WordPress → Perfmatters Configuration Generator"
  echo "=================================================="

  check_jq
  check_wp_cli
  check_wordpress

  if ! test_api; then
    error "Bailing: API not available."; exit 1
  fi

  local plugins_json theme_json domain_json
  plugins_json="$(get_plugins_json_array)"
  theme_json="$(get_theme_slugs_json "$@")"
  domain_json="$(get_domain_json)"

  # sanity checks on the JSON bits
  echo "$plugins_json" | jq . >/dev/null
  echo "$theme_json"   | jq . >/dev/null
  echo "$domain_json"  | jq . >/dev/null

  echo
  log "Summary:"
  echo "  Plugins: $(echo "$plugins_json" | jq length 2>/dev/null || echo "0")"
  echo "  Themes:  $(echo "$theme_json"   | jq -r '.themes | join(", ")')"
  echo "  Primary: $(echo "$theme_json"   | jq -r '.primary')"
  echo "  Domain:  $(echo "$domain_json"  | jq -r .)"
  echo

  if generate_config "$plugins_json" "$theme_json" "$domain_json"; then
    echo
    success "Config generated."
    echo

    # import (can't skip plugins here, so only skip-themes)
    log "Importing into Perfmatters…"
    if wp perfmatters import-settings "$OUTPUT_DIR/perfmatters-config-$TIMESTAMP.json" --skip-themes --allow-root; then
      success "Import done."

      # tidy up so we don't leave JSONs in webroot
      log "Cleaning up temp files…"
      rm -rf "$OUTPUT_DIR"
      success "Cleanup complete."
      echo
    else
      error "Import failed."
      exit 1
    fi
  else
    error "Config generation failed."; exit 1
  fi
}

main "$@"
