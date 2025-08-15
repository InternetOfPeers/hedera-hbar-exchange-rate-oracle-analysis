#!/bin/bash

# Exit on any error
set -euo pipefail

# CMC stats 1M with 1h interval gives different results for the same timestamps vs the other APIS, so I exclude them from the stats
SCRIPT_DIR=$(dirname "$0")
BASE_DIR="$SCRIPT_DIR/.."
FILENAME="$BASE_DIR/data/cmc-hbar-prices.csv"
FILENAME_1D=$(mktemp)
FILENAME_10D=$(mktemp)

# Clean up temp files on exit
trap "rm -f '$FILENAME_1D' '$FILENAME_10D'" EXIT

# Function to log messages with timestamp
timestamp() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S:%N')] CMC -"
}

echo -n "$(timestamp) Fetching data... "

fetch_cmc_data() {
    local filename="$1"
    local interval="$2"
    local range="$3"
    
    # Create a temporary file for processing
    local temp_file=$(mktemp)
    trap "rm -f '$temp_file'" EXIT
    
    # Fetch and process data in a single pipeline, excluding the last line
    if curl --silent --fail "https://api.coinmarketcap.com/data-api/v3.3/cryptocurrency/detail/chart?id=4642&interval=$interval&range=$range" | \
        jq -r ".data.points[] | [ .s, .v[0] ] | @csv" | \
        cut -c 1-22 | \
        sed 's/"//g' > "$temp_file"; then
        
        # Write header and all but the last line
        echo "timestamp,CMC" > "$filename"
        if [ -s "$temp_file" ]; then
            # Use sed to remove the last line (compatible with macOS)
            sed '$d' "$temp_file" >> "$filename"
        fi
        
        rm -f "$temp_file"
        return 0
    else
        rm -f "$temp_file"
        echo "ERROR: Failed to fetch data for range $range with interval $interval" >&2
        return 1
    fi
}

# Fetch data with error handling
if fetch_cmc_data "$FILENAME_10D" "15m" "10D" && fetch_cmc_data "$FILENAME_1D" "5m" "1D"; then
    echo "Done."
else
    echo "ERROR: Failed to fetch some data" >&2
    exit 1
fi

# Merge and update the current main file, while retaining old data
echo -n "$(timestamp) Merging data... "

temp_merged=$(mktemp)
trap "rm -f '$temp_merged'" EXIT

# Combine all files, remove duplicates, and sort in one operation
{
    [ -f "$FILENAME" ] && tail -n +2 "$FILENAME"  # Skip header from existing file
    [ -f "$FILENAME_10D" ] && tail -n +2 "$FILENAME_10D"  # Skip header
    [ -f "$FILENAME_1D" ] && tail -n +2 "$FILENAME_1D"   # Skip header
} | sort -n -t',' -k1,1 | awk -F',' '!seen[$1]++' > "$temp_merged"

# Write header and merged data
echo "timestamp,CMC" > "$FILENAME"
cat "$temp_merged" >> "$FILENAME"
rm -f "$temp_merged"

echo "Done."

# Check for duplicates more efficiently
echo -n "$(timestamp) Check duplicates... "
duplicates=$(tail -n +2 "$FILENAME" | cut -d"," -f1 | sort | uniq -d)
if [ -n "$duplicates" ]; then
    echo "DUPLICATES FOUND! Please give a look at $FILENAME before using it."
    echo "Here the list:"
    echo "$duplicates"
    exit 1
else
    echo "Done."
    exit 0
fi