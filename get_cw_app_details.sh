#!/bin/bash
set -e

# =============================================================================
# Cloudways Server Info Extractor with App Type Filtering
# Usage: bash script.sh [app_type|all]
# Examples: 
#   bash script.sh wordpress    # Shows wordpress + woocommerce
#   bash script.sh phpstack     # Shows only phpstack
#   bash script.sh all          # Shows all app types
# =============================================================================

# Get filter argument
FILTER_TYPE="${1:-all}"

# Convert to lowercase for comparison
FILTER_TYPE=$(echo "$FILTER_TYPE" | tr '[:upper:]' '[:lower:]')

echo "Filter: $FILTER_TYPE"
echo ""

# Load configuration
CONFIG_FILE="./cloudways_creds.env"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Configuration file not found: $CONFIG_FILE"
  exit 1
fi
source "$CONFIG_FILE"

# Check required variables
if [[ -z "${CW_EMAIL:-}" || -z "${CW_API_KEY:-}" ]]; then
  echo "ERROR: Missing required environment variables in $CONFIG_FILE"
  echo "Required: CW_EMAIL, CW_API_KEY"
  exit 1
fi

# Check dependencies
if ! command -v jq &> /dev/null; then
  echo "ERROR: jq is required but not installed"
  echo "Install with: sudo apt install jq (Ubuntu) or brew install jq (macOS)"
  exit 1
fi

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
echo "Fetching server and application data..."
SERVERS_RESPONSE=$(curl -s -X GET https://api.cloudways.com/api/v1/server \
  -H "Authorization: Bearer $ACCESS_TOKEN")

if ! echo "$SERVERS_RESPONSE" | jq -e '.servers' &>/dev/null; then
  echo "ERROR: Failed to fetch servers"
  echo "Response: $SERVERS_RESPONSE"
  exit 1
fi

echo "✓ Data fetched successfully"
echo ""
echo "Processing server and application information..."

# Extract and format the data - grouped by server IP with filtering
RESULT=$(echo "$SERVERS_RESPONSE" | jq -r --arg filter "$FILTER_TYPE" '
def should_include(app_type):
  if $filter == "all" then true
  elif $filter == "wordpress" then (app_type | test("^(wordpress|woocommerce|wordpressmu)$"))
  else (app_type == $filter)
  end;

[
  .servers[] | 
  . as $server |
  {
    key: .public_ip,
    value: {
      "master_user": .master_user,
      "ssh_command": "\(.master_user)@\(.public_ip)",
      "apps": [
        .apps[] |
        select(should_include(.application)) |
        {
          "domain": (if .cname != "" then .cname else .app_fqdn end),
          "database": .mysql_db_name,
          "app_type": .application,
          "webroot": "/home/master/applications/\(.mysql_db_name)/public_html/"
        }
      ]
    }
  } |
  select(.value.apps | length > 0)
] | 
from_entries')

# Count filtered results
APP_COUNT=$(echo "$RESULT" | jq '[.[].apps[]] | length')

# Output clean JSON
echo "$RESULT" | jq '.'

echo ""
echo "Found $APP_COUNT apps matching filter: $FILTER_TYPE"

# Save to file
OUTPUT_FILE="cloudways_${FILTER_TYPE}_$(date +%Y%m%d_%H%M%S).json"
echo "$RESULT" > "$OUTPUT_FILE"
echo "✓ Data saved to: $OUTPUT_FILE"
