#!/bin/bash
set -e

# =============================================================================
# Cloudways Migration Script
# Usage: bash script.sh [app_type|all]
# Examples:
#   bash script.sh wordpress    # WordPress + WooCommerce + WordPressMU
#   bash script.sh phpstack     # PHPStack apps only
#   bash script.sh all          # All app types (default)
# 
# Output:
#   - cloudways_data_[type]_[timestamp].json    # Full database
#   - all_domains_[timestamp].txt               # Clean domain list
# =============================================================================

# Get filter argument
FILTER_TYPE="${1:-all}"

# Convert to lowercase
FILTER_TYPE=$(echo "$FILTER_TYPE" | tr '[:upper:]' '[:lower:]')

echo "Cloudways Migration Script"
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
echo "Processing data..."

# Generate timestamp for consistent file naming
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Create JSON database (domain-centric structure)
JSON_DATA=$(echo "$SERVERS_RESPONSE" | jq -r --arg filter "$FILTER_TYPE" '
def should_include(app_type):
  if $filter == "all" then true
  elif $filter == "wordpress" then (app_type | test("^(wordpress|woocommerce|wordpressmu)$"))
  else (app_type == $filter)
  end;

[
  .servers[] |
  . as $server |
  .apps[] |
  select(should_include(.application)) |
  {
    key: (if .cname != "" then .cname else .app_fqdn end),
    value: {
      "ip": $server.public_ip,
      "master_user": $server.master_user,
      "ssh_command": "\($server.master_user)@\($server.public_ip)",
      "database": .mysql_db_name,
      "app_type": .application,
      "webroot": "/home/master/applications/\(.mysql_db_name)/public_html/"
    }
  }
] |
from_entries')

# Create domains list
DOMAINS_LIST=$(echo "$JSON_DATA" | jq -r 'keys[]' | sort)

# Count results
APP_COUNT=$(echo "$JSON_DATA" | jq 'keys | length')

# Save JSON database
JSON_FILE="cloudways_data_${FILTER_TYPE}_${TIMESTAMP}.json"
echo "$JSON_DATA" | jq '.' > "$JSON_FILE"

# Save domains list
DOMAINS_FILE="all_domains_${TIMESTAMP}.txt"
echo "$DOMAINS_LIST" > "$DOMAINS_FILE"

echo "✓ Processing complete"
echo ""
echo "Found $APP_COUNT apps matching filter: $FILTER_TYPE"
echo ""
echo "Files created:"
echo "📁 $JSON_FILE    # Full database"
echo "📁 $DOMAINS_FILE           # Domain list"
