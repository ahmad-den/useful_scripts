#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# checkmysite-upload.sh — Upload nginx access logs to stats.checkmysite.app
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
STATS_SERVER="https://stats.checkmysite.app"
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

ENDPOINT="${STATS_SERVER%/}/api/upload-batch"

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

  LOGFILES+=("$upload_file")
  LOGNAMES+=("$domain")
  FILESIZES+=("$upload_size")
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

  BATCH_RESPONSE=$(curl --silent --show-error --fail \
    --http1.1 \
    --max-time 600 \
    -H "Expect:" \
    "${HEADER_ARGS[@]+"${HEADER_ARGS[@]}"}" \
    "${BASE_ARGS[@]+"${BASE_ARGS[@]}"}" \
    "${append_args[@]+"${append_args[@]}"}" \
    "${batch_args[@]}" \
    "$ENDPOINT" 2>&1) || {
      printf '{"success":false,"error":"%s"}\n' "$(echo "$BATCH_RESPONSE" | tr '"' "'")"
      exit 1
    }

  # Capture uuid from first batch response; subsequent batches reuse it
  if [[ -z "$REPORT_UUID" ]]; then
    REPORT_UUID=$(echo "$BATCH_RESPONSE" | jq -r '.uuid // empty')
  fi

  ALL_RESPONSES+=("$BATCH_RESPONSE")
  batch_args=()
  batch_size=0
  batch_count=0
}

for idx in "${!LOGFILES[@]}"; do
  fpath="${LOGFILES[$idx]}"
  fname="${LOGNAMES[$idx]}"
  fsize="${FILESIZES[$idx]}"
  # Flush current batch if adding this file would exceed size or count limits
  if (( batch_count >= FILE_LIMIT || ( batch_count > 0 && batch_size + fsize > SIZE_LIMIT ) )); then
    do_flush
  fi
  batch_args+=(-F "files=@${fpath};filename=${fname}")
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
