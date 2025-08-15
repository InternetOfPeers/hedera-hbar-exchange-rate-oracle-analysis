#!/bin/bash

# Exit on any error
set -euo pipefail

SCRIPT_DIR=$(dirname "$0")
BASE_DIR="$SCRIPT_DIR/.."

cmc_file="${1:-$BASE_DIR/data/cmc-hbar-prices.csv}"
hedera_file="${2:-$BASE_DIR/data/hedera-hbar-prices.csv}"
output_file="${3:-$BASE_DIR/build/uncompressed-hbar-prices.csv}"

# Function to show usage
show_usage() {
    cat << 'EOF'

🔧 CSV Merger for HBAR Price Data

Usage: merge-and-fill-csv-data.sh <cmc-csv> <hedera-csv> [output-csv]

Arguments:
  cmc-csv      Path to CMC CSV file (with timestamp column)
  hedera-csv   Path to Hedera CSV file (with hour_start_timestamp column)
  output-csv   Output file path (default: ./data/merged-data.csv)

CMC CSV Format:
  timestamp,CMC
  1755269700,0.2472986
  ...

Hedera CSV Format:
  hour start date, HEDERA, hour_start_timestamp,cent_equivalent,hbar_equivalent
  2025-08-15T11:00:00Z,0.25325800,1755255600,759774,30000
  ...

Output Format:
  Date,CMC,HEDERA
  1755269700,0.2472986,0.25325800
  ...

Features:
- Matches timestamps between files
- Forward-fills missing Hedera values
- Handles different sampling rates
- Sorts output by timestamp

EOF
}

# Validate input files
if [ ! -f "$cmc_file" ]; then
    echo "ERROR: CMC CSV file not found: $cmc_file" >&2
    show_usage
    exit 1
fi

if [ ! -f "$hedera_file" ]; then
    echo "ERROR: Hedera CSV file not found: $hedera_file" >&2
    show_usage
    exit 1
fi

# Create output directory if it doesn't exist
output_dir=$(dirname "$output_file")
mkdir -p "$output_dir"

# Clean up temp files on exit
cleanup() {
    [ -n "${temp_hedera:-}" ] && rm -f "$temp_hedera"
    [ -n "${temp_cmc:-}" ] && rm -f "$temp_cmc"
    [ -n "${temp_merged:-}" ] && rm -f "$temp_merged"
    [ -n "${temp_output:-}" ] && rm -f "$temp_output"
}
trap cleanup EXIT

# Function to log messages with timestamp
timestamp() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S:%N')] MERGER -"
}

# Function to parse Hedera CSV and create lookup table
parse_hedera_csv() {
    local file="$1"
    local temp_file="$2"
    
    if [ ! -f "$file" ]; then
        echo "ERROR: Hedera CSV file not found: $file" >&2
        return 1
    fi
    
    # Parse Hedera CSV: extract timestamp and price, skip header
    # Use awk for better performance
    awk -F',' 'NR > 1 && NF >= 3 && $3 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+\.?[0-9]*$/ {
        gsub(/^[ \t]+|[ \t]+$/, "", $3)
        gsub(/^[ \t]+|[ \t]+$/, "", $2)
        print $3 "," $2
    }' "$file" | sort -n -t',' -k1,1 > "$temp_file"
}

# Function to parse CMC CSV
parse_cmc_csv() {
    local file="$1"
    local temp_file="$2"
    
    if [ ! -f "$file" ]; then
        echo "ERROR: CMC CSV file not found: $file" >&2
        return 1
    fi
    
    # Parse CMC CSV: extract timestamp and price, skip header
    # Use awk for better performance
    awk -F',' 'NR > 1 && NF >= 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+\.?[0-9]*$/ {
        gsub(/^[ \t]+|[ \t]+$/, "", $1)
        gsub(/^[ \t]+|[ \t]+$/, "", $2)
        print $1 "," $2
    }' "$file" | sort -n -t',' -k1,1 > "$temp_file"
}

# Function to merge CSV files
merge_csv_files() {
    local hedera_file="$1"
    local cmc_file="$2"
    local output_file="$3"
    
    echo -n "$(timestamp) Reading Hedera CSV file... "
    temp_hedera=$(mktemp)
    if ! parse_hedera_csv "$hedera_file" "$temp_hedera"; then
        echo "ERROR: Failed to parse Hedera CSV" >&2
        return 1
    fi
    local hedera_count=$(wc -l < "$temp_hedera")
    echo "Done. Loaded $hedera_count Hedera price points"
    
    echo -n "$(timestamp) Reading CMC CSV file... "
    temp_cmc=$(mktemp)
    if ! parse_cmc_csv "$cmc_file" "$temp_cmc"; then
        echo "ERROR: Failed to parse CMC CSV" >&2
        return 1
    fi
    local cmc_count=$(wc -l < "$temp_cmc")
    echo "Done. Loaded $cmc_count CMC price points"
    
    if [ "$cmc_count" -eq 0 ]; then
        echo "ERROR: No valid CMC data found" >&2
        return 1
    fi
    
    echo -n "$(timestamp) Merging data... "
    temp_output=$(mktemp)
    
    # Write header
    echo "Date,CMC,HEDERA" > "$temp_output"
    
    # Use awk for fast processing with simple forward-fill logic
    awk -F',' '
    BEGIN { 
        last_hedera_price = ""
        merged_count = 0
    }
    
    # Read all Hedera data into memory first
    FNR == NR {
        if (NF >= 2 && $1 != "" && $2 != "") {
            hedera_prices[$1] = $2
        }
        next
    }
    
    # Process CMC data with simple forward-fill
    {
        if (NF >= 2 && $1 != "" && $2 != "") {
            cmc_timestamp = $1
            cmc_price = $2
            hedera_price = ""
            
            # Try exact match first
            if (cmc_timestamp in hedera_prices) {
                hedera_price = hedera_prices[cmc_timestamp]
                last_hedera_price = hedera_price
            } else if (last_hedera_price != "") {
                # Simple forward fill - use previous value
                hedera_price = last_hedera_price
            }
            
            if (hedera_price != "") {
                print cmc_timestamp "," cmc_price "," hedera_price
                merged_count++
            }
        }
    }
    
    END {
        printf "MERGED_COUNT:%d\n", merged_count > "/dev/stderr"
    }
    ' "$temp_hedera" "$temp_cmc" >> "$temp_output" 2>/tmp/merge_stats
    
    # Get merged count from awk
    local merged_count=$(grep "MERGED_COUNT:" /tmp/merge_stats 2>/dev/null | cut -d: -f2 || echo "0")
    rm -f /tmp/merge_stats
    
    echo "Done. Merged $merged_count data points"
    
    echo -n "$(timestamp) Writing merged CSV... "
    mv "$temp_output" "$output_file"
    echo "Done. Data saved to: $output_file"
        
    return 0
}

# Perform the merge
if merge_csv_files "$hedera_file" "$cmc_file" "$output_file"; then
    echo "$(timestamp) Merge completed successfully."
    exit 0
else
    echo "$(timestamp) Merge failed."
    exit 1
fi
