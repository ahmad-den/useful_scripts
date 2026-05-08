#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# checkmysite-upload.sh — Upload nginx access logs to lens.checkmysite.app
#
# Drop this script on any BigScoots client server and run it.
# Looks for logs at: /home/nginx/domains/<domain>/log/access.log[.gz]
# The server IP is detected automatically via 'hostname -I'.
#
# Usage:
#   ./checkmysite-upload.sh
#   ./checkmysite-upload.sh --only example.com
#   ./checkmysite-upload.sh --path /custom/nginx/domains
#
# Options:
#   --only <domain>    Upload a single domain instead of all.
#   --path <dir>       Override base domains directory.
#                      Default: /home/nginx/domains
#   --log <filename>   Log filename inside each domain's log/ dir.
#                      Default: access.log  (also tries access.log.gz)
#   --token <token>    Auth token if your stats instance requires one.
#   --open             Open the report URL in the browser after upload (macOS/Linux).
#   -h / --help        Show this help and exit.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Temp directory (auto-cleaned on exit) ────────────────────────────────────
TMPDIR_UPLOAD=$(mktemp -d)
trap 'rm -rf "$TMPDIR_UPLOAD"' EXIT

# ── Defaults ──────────────────────────────────────────────────────────────────
STATS_SERVER="https://lens.checkmysite.app"
PATH_BASE="/home/nginx/domains"
LOG_SUBDIR="log"
LOG_FILENAME="access.log"
ONLY=""
TOKEN=""
OPEN_BROWSER=0

# Auto-detect this server's primary IP (skip loopback 127.x and 0.0.0.0)
SERVER_IP=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^127\.' | grep -v '^0\.0\.0\.0' | grep -v '^::1' | head -1 || true)

# ── Helpers ───────────────────────────────────────────────────────────────────
usage() {
  grep '^#' "$0" | sed 's/^# \{0,2\}//' | sed 's/^#//'
}

info()  { printf '\033[1;32m[✔]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
skip()  { printf '\033[1;35m[~]\033[0m %s\n' "$*" >&2; }
error() { printf '\033[1;31m[✘]\033[0m %s\n' "$*" >&2; }
die()   { error "$*"; exit 1; }

# Returns 0 (true) if the domain looks like a staging/dev/internal environment
is_staging_domain() {
  local d="$1"
  # BigScoots staging/WPO/dev hostnames
  [[ "$d" == *bigscoots-staging* ]] && return 0
  [[ "$d" == *bigscoots-wpo*     ]] && return 0
  [[ "$d" == *bigscoots-dev*     ]] && return 0
  # Generic staging/dev/test subdomains or suffixes
  [[ "$d" == staging.*   ]] && return 0
  [[ "$d" == dev.*       ]] && return 0
  [[ "$d" == test.*      ]] && return 0
  [[ "$d" == *.staging   ]] && return 0
  [[ "$d" == *.dev       ]] && return 0
  [[ "$d" == *.test      ]] && return 0
  [[ "$d" == *.local     ]] && return 0
  return 1
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)      ONLY="${2:?'--only requires a value'}";           shift 2 ;;
    --path)      PATH_BASE="${2:?'--path requires a value'}";      shift 2 ;;
    --log)       LOG_FILENAME="${2:?'--log requires a value'}";    shift 2 ;;
    --token)     TOKEN="${2:?'--token requires a value'}";         shift 2 ;;
    --open)      OPEN_BROWSER=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) die "Unknown option: $1  (run with --help for usage)" ;;
  esac
done

# ── Validation ────────────────────────────────────────────────────────────────
[[ -d "$PATH_BASE" ]] || die "Domains directory not found: $PATH_BASE"

command -v curl >/dev/null 2>&1 || die "'curl' is required but not installed"
command -v jq   >/dev/null 2>&1 || die "'jq' is required (apt install jq)"

# --http1.1 was added in curl 7.33; detect support to stay compatible with older servers
CURL_HTTP11=()
curl --http1.1 --version >/dev/null 2>&1 && CURL_HTTP11=(--http1.1)

ENDPOINT="${STATS_SERVER%/}/api/upload-batch"

# ── Server-level disk stats (collected once, best-effort) ────────────────────
SERVER_DISK_JSON='null'
_df_lines=$(df -k 2>/dev/null | awk 'NR>1' || true)
if [[ -n "$_df_lines" ]]; then
  _df_json=$(echo "$_df_lines" | awk '
    {
      pct=$5; gsub(/%/,"",pct)
      if ($1 ~ /^\/dev\// || $6 == "/") {
        printf "{\"device\":\"%s\",\"totalKB\":%d,\"usedKB\":%d,\"availKB\":%d,\"usePct\":%d,\"mountpoint\":\"%s\"}\n",
          $1, $2, $3, $4, pct, $6
      }
    }
  ' 2>/dev/null || true)
  [[ -n "$_df_json" ]] && SERVER_DISK_JSON=$(echo "$_df_json" | jq -s '.' 2>/dev/null) || true
fi

# ── Collect domain directories ────────────────────────────────────────────────
declare -a DOMAINS=()

if [[ -n "$ONLY" ]]; then
  [[ -d "${PATH_BASE%/}/$ONLY" ]] || die "Domain directory not found: ${PATH_BASE%/}/$ONLY"
  DOMAINS+=("$ONLY")
else
  while IFS= read -r -d '' dir; do
    domain="$(basename "$dir")"
    [[ "$domain" == .* ]] && continue
    DOMAINS+=("$domain")
  done < <(find "$PATH_BASE" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
fi

[[ ${#DOMAINS[@]} -gt 0 ]] || die "No domain subdirectories found under $PATH_BASE"

# ── Build upload file list ───────────────────────────────────────────────────
declare -a HEADER_ARGS=()
declare -a BASE_ARGS=()
declare -a LOGFILES=()
declare -a LOGNAMES=()
declare -a FILESIZES=()
declare -a DISKSTATS=()
declare -a NCDU_GZ_FILES=()   # parallel to LOGNAMES; "" if no ncdu for that domain
FOUND=0
SKIPPED=0

# Auth header (optional)
[[ -n "$TOKEN" ]] && HEADER_ARGS+=(-H "Authorization: Bearer ${TOKEN}")

# Server IP form field (optional)
[[ -n "$SERVER_IP" ]] && BASE_ARGS+=(-F "serverIp=${SERVER_IP}")

STAGING_SKIPPED=0

for domain in "${DOMAINS[@]}"; do
  # Skip staging / dev / internal environments before anything else
  if is_staging_domain "$domain"; then
    skip "Skipping staging/dev domain: ${domain}"
    (( STAGING_SKIPPED++ )) || true
    continue
  fi

  log_dir="${PATH_BASE%/}/${domain}/${LOG_SUBDIR}"

  if   [[ -f "${log_dir}/${LOG_FILENAME}" ]]; then
    logfile="${log_dir}/${LOG_FILENAME}"
  elif [[ -f "${log_dir}/${LOG_FILENAME}.gz" ]]; then
    logfile="${log_dir}/${LOG_FILENAME}.gz"
  else
    warn "No log found for ${domain}  (looked in ${log_dir}/${LOG_FILENAME}[.gz]) — skipping"
    (( SKIPPED++ )) || true
    continue
  fi

  # Skip empty log files (would cause a 422 from the server)
  raw_size=$(stat -c%s "$logfile" 2>/dev/null || stat -f%z "$logfile" 2>/dev/null || echo 0)
  if [[ "$raw_size" -eq 0 ]]; then
    skip "Empty log file for ${domain} — skipping"
    (( SKIPPED++ )) || true
    continue
  fi

  size_human=$(du -sh "$logfile" 2>/dev/null | cut -f1)

  # Compress to tmp if not already gzipped (reduces 34MB → ~3MB, solves Cloudflare 100MB limit)
  if [[ "$logfile" == *.gz ]]; then
    upload_file="$logfile"
  else
    upload_file="${TMPDIR_UPLOAD}/${domain}.gz"
    gzip -c "$logfile" > "$upload_file"
  fi
  upload_size=$(stat -c%s "$upload_file" 2>/dev/null || stat -f%z "$upload_file" 2>/dev/null || echo 0)
  upload_size_human=$(du -sh "$upload_file" 2>/dev/null | cut -f1)

  info "Queuing  ${domain}  (${size_human:-?} → ${upload_size_human:-?} compressed)"

  # ── Collect disk stats (best-effort, non-blocking) ─────────────────────────
  disk_json='null'
  public_dir="${PATH_BASE%/}/${domain}/public"
  if [[ -d "$public_dir" ]]; then
    pub_human=$(du -sh "$public_dir" 2>/dev/null | awk '{print $1}' || echo "?")
    pub_kb=$(du -sk "$public_dir" 2>/dev/null | awk '{print $1}' || echo 0)
    [[ "$pub_kb" =~ ^[0-9]+$ ]] || pub_kb=0

    uploads_human=$(du -sh "${public_dir}/wp-content/uploads" 2>/dev/null | awk '{print $1}' || true)
    plugins_human=$(du -sh "${public_dir}/wp-content/plugins" 2>/dev/null | awk '{print $1}' || true)
    themes_human=$(du -sh  "${public_dir}/wp-content/themes"  2>/dev/null | awk '{print $1}' || true)
    uploads_kb=$(du -sk "${public_dir}/wp-content/uploads" 2>/dev/null | awk '{print $1}' || echo 0)
    plugins_kb=$(du -sk "${public_dir}/wp-content/plugins" 2>/dev/null | awk '{print $1}' || echo 0)
    themes_kb=$(du -sk  "${public_dir}/wp-content/themes"  2>/dev/null | awk '{print $1}' || echo 0)
    [[ "$uploads_kb" =~ ^[0-9]+$ ]] || uploads_kb=0
    [[ "$plugins_kb" =~ ^[0-9]+$ ]] || plugins_kb=0
    [[ "$themes_kb"  =~ ^[0-9]+$ ]] || themes_kb=0

    db_size=""
    db_size_kb=0
    if command -v wp >/dev/null 2>&1 && [[ -f "${public_dir}/wp-config.php" ]]; then
      _raw=$(wp --path="$public_dir" --allow-root db query \
        "SELECT ROUND(SUM(data_length + index_length) / 1024, 0) FROM information_schema.tables WHERE table_schema = DATABASE();" \
        --skip-column-names 2>/dev/null | tr -d '[:space:]' || true)
      [[ "$_raw" =~ ^[0-9]+$ ]] && db_size_kb=$_raw
      if [[ "$db_size_kb" -gt 0 ]]; then
        db_size=$(awk -v kb="$db_size_kb" 'BEGIN {
          if      (kb >= 1048576) printf "%.1fGiB", kb/1048576
          else if (kb >= 1024)   printf "%.1fMiB", kb/1024
          else                   printf "%dKiB",   kb
        }')
      fi
    fi

    # ── ncdu full tree (uploaded as separate gz file for interactive UI) ─────
    _ncdu_gz=""
    if command -v ncdu >/dev/null 2>&1; then
      _ncdu_json_tmp=$(mktemp /tmp/ncdu_XXXXXX.json)
      _ncdu_gz_tmp=$(mktemp /tmp/ncdu_XXXXXX.json.gz)
      if timeout 180 ncdu -0 -o "$_ncdu_json_tmp" "$public_dir" 2>/dev/null \
          && [[ -s "$_ncdu_json_tmp" ]]; then
        gzip -c "$_ncdu_json_tmp" > "$_ncdu_gz_tmp" && _ncdu_gz="$_ncdu_gz_tmp"
      fi
      rm -f "$_ncdu_json_tmp"
      [[ -z "$_ncdu_gz" ]] && rm -f "$_ncdu_gz_tmp"
    fi

    disk_json=$(jq -n \
      --arg     pub          "$pub_human" \
      --argjson pubBytes     "$(( pub_kb * 1024 ))" \
      --arg     db           "$db_size" \
      --argjson dbBytes      "$(( db_size_kb * 1024 ))" \
      --arg     uploads      "${uploads_human:-}" \
      --argjson uploadsBytes "$(( uploads_kb * 1024 ))" \
      --arg     plugins      "${plugins_human:-}" \
      --argjson pluginsBytes "$(( plugins_kb * 1024 ))" \
      --arg     themes       "${themes_human:-}" \
      --argjson themesBytes  "$(( themes_kb * 1024 ))" \
      --arg     ts           "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{
        publicDirSize: $pub,
        publicDirBytes: $pubBytes,
        dbSize:       (if $db      == "" then null else $db      end),
        dbSizeBytes:  $dbBytes,
        uploads:      (if $uploads == "" then null else $uploads end),
        uploadsBytes: $uploadsBytes,
        plugins:      (if $plugins == "" then null else $plugins end),
        pluginsBytes: $pluginsBytes,
        themes:       (if $themes  == "" then null else $themes  end),
        themesBytes:  $themesBytes,
        collectedAt:  $ts
      }') 2>/dev/null || disk_json='null'
  fi

  LOGFILES+=("$upload_file")
  LOGNAMES+=("$domain")
  FILESIZES+=("$upload_size")
  DISKSTATS+=("$disk_json")
  NCDU_GZ_FILES+=("${_ncdu_gz:-}")
  (( FOUND++ )) || true
done

(( FOUND > 0 )) || die "No log files found for any domain under $PATH_BASE"

# ── Upload (size-based batching: ≤70 MB and ≤8 files per request) ─────────────
# 70 MB keeps each request safely under Cloudflare's 100 MB free-plan limit.
echo
printf '\033[1;37mUploading %d log file(s) to %s …\033[0m\n' "$FOUND" "$ENDPOINT"
[[ -n "$SERVER_IP" ]] && printf '\033[1;37mServer IP: %s (auto-detected)\033[0m\n' "$SERVER_IP"
echo

SIZE_LIMIT=$(( 70 * 1024 * 1024 ))   # 70 MB per batch
FILE_LIMIT=8                          # also cap at 8 files per batch

declare -a ALL_RESPONSES=()
declare -a batch_args=()
declare -a batch_disk_parts=()
declare -a batch_ncdu_args=()
BATCH_NUM=0
batch_size=0
batch_count=0
REPORT_UUID=""   # set after first batch; subsequent batches append to same report

do_flush() {
  [[ ${#batch_args[@]} -eq 0 ]] && return
  (( BATCH_NUM++ )) || true
  printf '\033[1;37mBatch %d: uploading %d file(s)…\033[0m\n' "$BATCH_NUM" "$batch_count"

  # Build append-uuid arg if this is not the first batch
  local -a append_args=()
  [[ -n "$REPORT_UUID" ]] && append_args+=(-F "appendUuid=${REPORT_UUID}")

  BATCH_RESPONSE=$(curl --silent --show-error \
    "${CURL_HTTP11[@]+"${CURL_HTTP11[@]}"}" \
    --max-time 600 \
    --write-out '\nHTTP_STATUS:%{http_code}' \
    -H "Expect:" \
    "${HEADER_ARGS[@]+"${HEADER_ARGS[@]}"}" \
    "${BASE_ARGS[@]+"${BASE_ARGS[@]}"}" \
    "${append_args[@]+"${append_args[@]}"}" \
    -F "diskStats=[$(IFS=','; echo "${batch_disk_parts[*]}")]" \
    -F "serverDisk=${SERVER_DISK_JSON}" \
    "${batch_ncdu_args[@]+"${batch_ncdu_args[@]}"}" \
    "${batch_args[@]}" \
    "$ENDPOINT" 2>&1)

  HTTP_STATUS=$(echo "$BATCH_RESPONSE" | grep -o 'HTTP_STATUS:[0-9]*' | cut -d: -f2)
  BATCH_RESPONSE=$(echo "$BATCH_RESPONSE" | grep -v 'HTTP_STATUS:')

  if [[ "${HTTP_STATUS:-0}" -ge 400 ]]; then
    SERVER_MSG=$(echo "$BATCH_RESPONSE" | jq -r '.error // .message // empty' 2>/dev/null || true)
    if [[ -n "$SERVER_MSG" ]]; then
      error "Batch ${BATCH_NUM} failed (HTTP ${HTTP_STATUS}): ${SERVER_MSG}"
    else
      error "Batch ${BATCH_NUM} failed (HTTP ${HTTP_STATUS}): ${BATCH_RESPONSE}"
    fi
    exit 1
  fi

  # Capture uuid from first batch response; subsequent batches reuse it
  if [[ -z "$REPORT_UUID" ]]; then
    REPORT_UUID=$(echo "$BATCH_RESPONSE" | jq -r '.uuid // empty')
  fi

  ALL_RESPONSES+=("$BATCH_RESPONSE")
  batch_args=()
  batch_disk_parts=()
  batch_ncdu_args=()
  batch_size=0
  batch_count=0
}

for idx in "${!LOGFILES[@]}"; do
  fpath="${LOGFILES[$idx]}"
  fname="${LOGNAMES[$idx]}"
  fsize="${FILESIZES[$idx]}"
  fncdu="${NCDU_GZ_FILES[$idx]:-}"
  # Flush current batch if adding this file would exceed size or count limits
  if (( batch_count >= FILE_LIMIT || ( batch_count > 0 && batch_size + fsize > SIZE_LIMIT ) )); then
    do_flush
  fi
  batch_args+=(-F "files=@${fpath};filename=${fname}")
  batch_disk_parts+=("{\"domain\":$(printf '%s' "${fname}" | jq -Rs .),\"stats\":${DISKSTATS[$idx]}}")
  # Attach ncdu gz as a separate file with special filename prefix
  [[ -n "$fncdu" && -f "$fncdu" ]] && batch_ncdu_args+=(-F "files=@${fncdu};filename=__ncdu__${fname}")
  (( batch_size  += fsize )) || true
  (( batch_count += 1     )) || true
done
do_flush

# ── Parse and output JSON ─────────────────────────────────────────────────────
# All batches share the same report UUID — output is always a single object.
RESPONSE="${ALL_RESPONSES[0]}"
if ! echo "$RESPONSE" | jq -e '.reportUrl' >/dev/null 2>&1; then
  printf '{"success":false,"error":"Unexpected server response","raw":"%s"}\n' \
    "$(echo "$RESPONSE" | tr '"' "'" | head -c 200)"
  exit 1
fi
REPORT_URL=$(echo "$RESPONSE" | jq -r '.reportUrl')

# Count total domains across all batches
TOTAL_PROCESSED=0
ALL_DOMAINS='[]'
for r in "${ALL_RESPONSES[@]}"; do
  TOTAL_PROCESSED=$(( TOTAL_PROCESSED + $(echo "$r" | jq '.domainsProcessed') ))
  ALL_DOMAINS=$(echo "$ALL_DOMAINS" | jq --argjson d "$(echo "$r" | jq '[.domains[]|{domain,requests}]')" '. + $d')
done

jq -n \
  --arg url "$REPORT_URL" \
  --argjson processed "$TOTAL_PROCESSED" \
  --arg skipped "$SKIPPED" \
  --arg staging "$STAGING_SKIPPED" \
  --argjson domains "$ALL_DOMAINS" \
  '{success:true, reportUrl:$url, domainsProcessed:$processed,
    skippedNoLog:($skipped|tonumber), skippedStagingDev:($staging|tonumber),
    domains:$domains}'

# ── Open browser (optional) ───────────────────────────────────────────────────
if [[ "$OPEN_BROWSER" -eq 1 ]]; then
  if   command -v xdg-open >/dev/null 2>&1; then xdg-open "$REPORT_URL"
  elif command -v open     >/dev/null 2>&1; then open     "$REPORT_URL"
  else warn "Could not open browser (tried xdg-open / open)"
  fi
fi
