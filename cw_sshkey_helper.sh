#!/bin/bash
set -e

# =============================================================================
# Cloudways SSH Key Upload Script with Logging
# =============================================================================

# Setup logging
LOG_DIR="./logs"
LOG_FILE="$LOG_DIR/cloudways_ssh_$(date +%Y%m%d_%H%M%S).log"

# Create logs directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Function to log messages to both console and file
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" | tee -a "$LOG_FILE"
}

# Function to log debug info (only to file)
debug() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] DEBUG: $message" >> "$LOG_FILE"
}

# Redirect all output to both console and log file
exec > >(tee -a "$LOG_FILE")
exec 2> >(tee -a "$LOG_FILE" >&2)

log "=== Starting Cloudways SSH Key Upload Script ==="
log "Log file: $LOG_FILE"

# Load configuration
CONFIG_FILE="./cloudways_creds.env"
log "Loading configuration from: $CONFIG_FILE"
if [[ ! -f "$CONFIG_FILE" ]]; then
  log "ERROR: Configuration file not found: $CONFIG_FILE"
  exit 1
fi
source "$CONFIG_FILE"
debug "Configuration loaded successfully"

# Check required variables
if [[ -z "${CW_EMAIL:-}" || -z "${CW_API_KEY:-}" || -z "${CW_SSH_KEY_PATH:-}" || -z "${CW_SSH_KEY_NAME:-}" ]]; then
  log "ERROR: Missing required environment variables in $CONFIG_FILE"
  log "Required: CW_EMAIL, CW_API_KEY, CW_SSH_KEY_PATH, CW_SSH_KEY_NAME"
  exit 1
fi
debug "All required environment variables found"

# Check dependencies
log "Checking dependencies..."
for cmd in curl jq; do
  if ! command -v "$cmd" &> /dev/null; then
    log "ERROR: $cmd is required but not installed"
    exit 1
  fi
done
debug "All dependencies satisfied"

log "Authenticating with Cloudways..."
debug "Using email: $CW_EMAIL"
AUTH_RESPONSE=$(curl -s -X POST https://api.cloudways.com/api/v1/oauth/access_token \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$CW_EMAIL\",\"api_key\":\"$CW_API_KEY\"}")

ACCESS_TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.access_token // empty')
if [[ -z "$ACCESS_TOKEN" || "$ACCESS_TOKEN" == "null" ]]; then
  log "ERROR: Authentication failed"
  debug "Auth response: $AUTH_RESPONSE"
  exit 1
fi
log "✓ Authenticated successfully"
debug "Access token obtained (length: ${#ACCESS_TOKEN} chars)"

echo ""
log "Fetching servers..."
SERVERS_RESPONSE=$(curl -s -X GET https://api.cloudways.com/api/v1/server \
  -H "Authorization: Bearer $ACCESS_TOKEN")

if ! echo "$SERVERS_RESPONSE" | jq -e '.servers' &>/dev/null; then
  log "ERROR: Failed to fetch servers"
  debug "Server response: $SERVERS_RESPONSE"
  exit 1
fi
debug "Server data fetched successfully"

ALL_SERVERS=$(echo "$SERVERS_RESPONSE" | jq -r '.servers[] | "\(.id):\(.status)"')
RUNNING_SERVERS=$(echo "$ALL_SERVERS" | awk -F: '$2 == "running" {print $1}')
STOPPED_SERVERS=$(echo "$ALL_SERVERS" | awk -F: '$2 != "running" {print $1}')

echo "All servers: $(echo "$ALL_SERVERS" | cut -d':' -f1 | tr '\n' ' ')"
echo "Running: $(echo "$RUNNING_SERVERS" | tr '\n' ' ')"
echo "Stopped: $(echo "$STOPPED_SERVERS" | tr '\n' ' ')"

debug "Total servers: $(echo "$ALL_SERVERS" | wc -l)"
debug "Running servers: $(echo "$RUNNING_SERVERS" | wc -l)"
debug "Stopped servers: $(echo "$STOPPED_SERVERS" | wc -l)"

echo ""
log "Preparing SSH key..."
debug "SSH key path: $CW_SSH_KEY_PATH"
if [[ ! -f "$CW_SSH_KEY_PATH" ]]; then
  log "ERROR: SSH key file not found: $CW_SSH_KEY_PATH"
  exit 1
fi

SSH_KEY_CONTENT=$(cat "$CW_SSH_KEY_PATH")
if [[ ! "$SSH_KEY_CONTENT" =~ ^ssh-(rsa|ed25519|ecdsa) ]]; then
  log "ERROR: Invalid SSH key format"
  exit 1
fi

SSH_KEY_ENCODED=$(printf '%s' "$SSH_KEY_CONTENT" | jq -sRr @uri)
log "✓ SSH key prepared (${#SSH_KEY_CONTENT} characters)"
debug "SSH key name: $CW_SSH_KEY_NAME"
debug "SSH key encoded length: ${#SSH_KEY_ENCODED} characters"

echo ""
log "Uploading SSH key to running servers..."

TOTAL_SERVERS=$(echo "$RUNNING_SERVERS" | wc -l)
SUCCESS_COUNT=0
FAILED_SERVERS=()

debug "Starting upload process for $TOTAL_SERVERS servers"
debug "Rate limiting: 2 seconds between uploads"

# Process each server ID (compatible with older bash versions)
while IFS= read -r SERVER_ID; do
  # Skip empty lines
  [[ -z "$SERVER_ID" ]] && continue
  
  echo -n "Server $SERVER_ID: "
  debug "Processing server: $SERVER_ID"
  
  # Disable exit-on-error for this section only
  set +e
  UPLOAD_RESPONSE=$(curl -s -X POST https://api.cloudways.com/api/v1/ssh_key \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "Accept: application/json" \
    -d "server_id=$SERVER_ID&ssh_key_name=$CW_SSH_KEY_NAME&ssh_key=$SSH_KEY_ENCODED" 2>/dev/null)
  
  # Check curl exit code
  CURL_EXIT_CODE=$?
  # Re-enable exit-on-error
  set -e
  
  debug "Server $SERVER_ID - Curl exit code: $CURL_EXIT_CODE"
  
  if [[ $CURL_EXIT_CODE -ne 0 ]]; then
    echo "FAILED - curl error (exit code: $CURL_EXIT_CODE)"
    debug "Server $SERVER_ID - Curl failed with exit code: $CURL_EXIT_CODE"
    FAILED_SERVERS+=("$SERVER_ID")
    continue
  fi
  
  debug "Server $SERVER_ID - Response: $UPLOAD_RESPONSE"
  
  # Parse response (disable exit-on-error for jq operations that might fail)
  set +e
  KEY_ID=$(echo "$UPLOAD_RESPONSE" | jq -r '.id // empty' 2>/dev/null)
  ERROR_MSG=$(echo "$UPLOAD_RESPONSE" | jq -r '.message // "Unknown error"' 2>/dev/null)
  set -e
  
  if [[ -n "$KEY_ID" && "$KEY_ID" != "null" ]]; then
    echo "SUCCESS (Key ID: $KEY_ID)"
    debug "Server $SERVER_ID - Success: Key ID $KEY_ID"
    ((SUCCESS_COUNT++))
  else
    if [[ "$ERROR_MSG" == *"already exists"* ]]; then
      echo "Key already exists (OK)"
      debug "Server $SERVER_ID - Key already exists (counted as success)"
      ((SUCCESS_COUNT++))
    else
      echo "FAILED - $ERROR_MSG"
      debug "Server $SERVER_ID - Failed: $ERROR_MSG"
      FAILED_SERVERS+=("$SERVER_ID")
    fi
  fi
  
  # Delay to avoid rate limiting
  debug "Server $SERVER_ID - Waiting 2 seconds before next upload"
  sleep 2
done <<< "$RUNNING_SERVERS"

echo ""
echo "===================="
echo "SUMMARY"
echo "===================="
echo "Total servers: $TOTAL_SERVERS"
echo "Successful: $SUCCESS_COUNT"
echo "Failed: $((TOTAL_SERVERS - SUCCESS_COUNT))"

if [[ $SUCCESS_COUNT -eq $TOTAL_SERVERS ]]; then
  echo "Status: ALL SUCCESSFUL ✓"
  exit 0
else
  echo "Status: SOME FAILURES"
  if [[ ${#FAILED_SERVERS[@]} -gt 0 ]]; then
    echo "Failed servers: ${FAILED_SERVERS[*]}"
  fi
  exit 1
fi
