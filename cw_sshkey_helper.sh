#!/bin/bash
set -e

# =============================================================================
# Cloudways SSH Key Upload Script
# =============================================================================

# Load configuration
CONFIG_FILE="./cloudways_creds.env"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Configuration file not found: $CONFIG_FILE"
  exit 1
fi
source "$CONFIG_FILE"

# Check required variables
if [[ -z "${CW_EMAIL:-}" || -z "${CW_API_KEY:-}" || -z "${CW_SSH_KEY_PATH:-}" || -z "${CW_SSH_KEY_NAME:-}" ]]; then
  echo "ERROR: Missing required environment variables in $CONFIG_FILE"
  echo "Required: CW_EMAIL, CW_API_KEY, CW_SSH_KEY_PATH, CW_SSH_KEY_NAME"
  exit 1
fi

# Check dependencies
for cmd in curl jq; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "ERROR: $cmd is required but not installed"
    exit 1
  fi
done

echo "Authenticating with Cloudways..."
AUTH_RESPONSE=$(curl -s -X POST https://api.cloudways.com/api/v1/oauth/access_token \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$CW_EMAIL\",\"api_key\":\"$CW_API_KEY\"}")

ACCESS_TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.access_token // empty')
if [[ -z "$ACCESS_TOKEN" || "$ACCESS_TOKEN" == "null" ]]; then
  echo "ERROR: Authentication failed"
  echo "Response: $AUTH_RESPONSE"
  exit 1
fi
echo "✓ Authenticated successfully"

echo ""
echo "Fetching servers..."
SERVERS_RESPONSE=$(curl -s -X GET https://api.cloudways.com/api/v1/server \
  -H "Authorization: Bearer $ACCESS_TOKEN")

if ! echo "$SERVERS_RESPONSE" | jq -e '.servers' &>/dev/null; then
  echo "ERROR: Failed to fetch servers"
  echo "Response: $SERVERS_RESPONSE"
  exit 1
fi

ALL_SERVERS=$(echo "$SERVERS_RESPONSE" | jq -r '.servers[] | "\(.id):\(.status)"')
RUNNING_SERVERS=$(echo "$ALL_SERVERS" | awk -F: '$2 == "running" {print $1}')
STOPPED_SERVERS=$(echo "$ALL_SERVERS" | awk -F: '$2 != "running" {print $1}')

echo "All servers: $(echo "$ALL_SERVERS" | cut -d':' -f1 | tr '\n' ' ')"
echo "Running: $(echo "$RUNNING_SERVERS" | tr '\n' ' ')"
echo "Stopped: $(echo "$STOPPED_SERVERS" | tr '\n' ' ')"

echo ""
echo "Preparing SSH key..."
if [[ ! -f "$CW_SSH_KEY_PATH" ]]; then
  echo "ERROR: SSH key file not found: $CW_SSH_KEY_PATH"
  exit 1
fi

SSH_KEY_CONTENT=$(cat "$CW_SSH_KEY_PATH")
if [[ ! "$SSH_KEY_CONTENT" =~ ^ssh-(rsa|ed25519|ecdsa) ]]; then
  echo "ERROR: Invalid SSH key format"
  exit 1
fi

SSH_KEY_ENCODED=$(printf '%s' "$SSH_KEY_CONTENT" | jq -sRr @uri)
echo "✓ SSH key prepared (${#SSH_KEY_CONTENT} characters)"

echo ""
echo "Uploading SSH key to running servers..."

TOTAL_SERVERS=$(echo "$RUNNING_SERVERS" | wc -l)
SUCCESS_COUNT=0
FAILED_SERVERS=()

for SERVER_ID in $RUNNING_SERVERS; do
  echo -n "Server $SERVER_ID: "
  
  UPLOAD_RESPONSE=$(curl -s -X POST https://api.cloudways.com/api/v1/ssh_key \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "Accept: application/json" \
    -d "server_id=$SERVER_ID&ssh_key_name=$CW_SSH_KEY_NAME&ssh_key=$SSH_KEY_ENCODED")
  
  KEY_ID=$(echo "$UPLOAD_RESPONSE" | jq -r '.id // empty')
  
  if [[ -n "$KEY_ID" && "$KEY_ID" != "null" ]]; then
    echo "SUCCESS (Key ID: $KEY_ID)"
    ((SUCCESS_COUNT++))
  else
    ERROR_MSG=$(echo "$UPLOAD_RESPONSE" | jq -r '.message // "Unknown error"')
    if [[ "$ERROR_MSG" == *"already exists"* ]]; then
      echo "Key already exists (OK)"
      ((SUCCESS_COUNT++))
    else
      echo "FAILED - $ERROR_MSG"
      FAILED_SERVERS+=("$SERVER_ID")
    fi
  fi
done

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
