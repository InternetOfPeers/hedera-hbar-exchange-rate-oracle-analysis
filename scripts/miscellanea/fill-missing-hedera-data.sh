#!/bin/bash

# Missing Data Filler Script for Hedera HBAR Prices
# Analyzes the CSV file for missing hours and fills gaps by calling the API
# Usage: ./fill-missing-hedera-data.sh [csv_file]

set -euo pipefail

# Configuration
readonly SCRIPT_DIR=$(dirname "$0")
readonly BASE_DIR="$SCRIPT_DIR/.."
readonly DEFAULT_CSV_FILE="$BASE_DIR/data/hedera-hbar-prices.csv"
readonly API_BASE_URL="https://mainnet.mirrornode.hedera.com/api/v1/network/exchangerate"
readonly TEMP_DIR="$BASE_DIR/build/temp"

# Create temp directory
mkdir -p "$TEMP_DIR"

# Function to display usage
usage() {
    echo "Usage: $0 [csv_file]"
    echo "  csv_file: Path to the CSV file to analyze (default: $DEFAULT_CSV_FILE)"
    echo "Example: $0 data/hedera-hbar-prices.csv"
    exit 1
}

# Function to log messages with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S:%N')] $1" >&2
}

# Function to convert timestamp to human readable date
timestamp_to_date() {
    # macOS/BSD date first, then GNU date as fallback
    date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'
}

# Function to calculate HBAR price in USD
calculate_hbar_price() {
    local cent_equivalent=$1
    local hbar_equivalent=$2
    echo "scale=8; $cent_equivalent / $hbar_equivalent / 100" | bc -z
}

# Function to make API request
make_api_request() {
    local timestamp=$1
    local url="${API_BASE_URL}?timestamp=lt:$timestamp"
        
    # Make request with timeout and error handling
    if response=$(curl -s --max-time 30 --fail "$url" 2>/dev/null); then
        echo "$response"
        return 0
    else
        log "ERROR: Failed to fetch data for timestamp $timestamp"
        return 1
    fi
}

# Function to parse JSON response and extract rate for specific timestamp
parse_response_for_timestamp() {
    local response=$1
    local target_timestamp=$2
    
    # Extract all values in a single jq call for efficiency
    local json_values=$(echo "$response" | jq -r '[
        .current_rate.cent_equivalent,
        .current_rate.hbar_equivalent,
        .current_rate.expiration_time,
        .next_rate.cent_equivalent,
        .next_rate.hbar_equivalent,
        .next_rate.expiration_time
    ] | @csv' | sed 's/"//g')
    
    # Parse the CSV values
    IFS=',' read -r current_cent current_hbar current_expiration next_cent next_hbar next_expiration <<< "$json_values"
    
    # Validate extracted values
    if [[ -z "$current_cent" || -z "$current_hbar" || -z "$current_expiration" ||
          -z "$next_cent" || -z "$next_hbar" || -z "$next_expiration" ]]; then
        log "ERROR: Failed to parse response for target timestamp $target_timestamp"
        return 1
    fi
    
    # Determine which rate applies to our target timestamp
    local current_hour_start=$((current_expiration - 3600))
    local next_hour_start=$((next_expiration - 3600))
    
    if [[ $target_timestamp -eq $current_hour_start ]]; then
        # Use current rate
        local price=$(calculate_hbar_price "$current_cent" "$current_hbar")
        echo "$(timestamp_to_date $target_timestamp),$price,$target_timestamp,$current_cent,$current_hbar"
        return 0
    elif [[ $target_timestamp -eq $next_hour_start ]]; then
        # Use next rate
        local price=$(calculate_hbar_price "$next_cent" "$next_hbar")
        echo "$(timestamp_to_date $target_timestamp),$price,$target_timestamp,$next_cent,$next_hbar"
        return 0
    else
        log "ERROR: Target timestamp $target_timestamp not found in API response (current: $current_hour_start, next: $next_hour_start)"
        return 1
    fi
}

# Function to fetch missing data for a specific timestamp
fetch_missing_data() {
    local missing_timestamp=$1
    local query_timestamp=$((missing_timestamp + 3600))  # Query 1 hour ahead
    
    log "Fetching data for missing timestamp: $missing_timestamp ($(timestamp_to_date $missing_timestamp))"
    
    if response=$(make_api_request "$query_timestamp"); then
        if parsed_data=$(parse_response_for_timestamp "$response" "$missing_timestamp"); then
            echo "$parsed_data"
            return 0
        else
            log "ERROR: Failed to parse data for timestamp $missing_timestamp"
            return 1
        fi
    else
        log "ERROR: Failed to fetch data for timestamp $missing_timestamp"
        return 1
    fi
}

# Function to analyze CSV and find missing hours
analyze_missing_hours() {
    local csv_file=$1
    local temp_missing="$TEMP_DIR/missing_timestamps.txt"
    
    log "Analyzing CSV file: $csv_file"
    
    # Extract all timestamps from the CSV (skip header)
    local existing_timestamps=$(tail -n +2 "$csv_file" | cut -d',' -f3 | sort -n)
    
    if [[ -z "$existing_timestamps" ]]; then
        log "ERROR: No data found in CSV file"
        return 1
    fi
    
    # Get the range of timestamps
    local first_timestamp=$(echo "$existing_timestamps" | head -n 1)
    local last_timestamp=$(echo "$existing_timestamps" | tail -n 1)
    
    log "Data range: $(timestamp_to_date $first_timestamp) to $(timestamp_to_date $last_timestamp)"
    
    # Generate expected hourly timestamps and find missing ones
    local current_timestamp=$first_timestamp
    local missing_count=0
    
    > "$temp_missing"  # Clear the file
    
    while [[ $current_timestamp -le $last_timestamp ]]; do
        if ! echo "$existing_timestamps" | grep -q "^$current_timestamp$"; then
            echo "$current_timestamp" >> "$temp_missing"
            ((missing_count++))
        fi
        current_timestamp=$((current_timestamp + 3600))  # Add 1 hour
    done
    
    log "Found $missing_count missing hours"
    
    if [[ $missing_count -gt 0 ]]; then
        log "Missing timestamps:"
        while read -r ts; do
            log "  $ts ($(timestamp_to_date $ts))"
        done < "$temp_missing"
    fi
    
    echo "$temp_missing"
}

# Function to fill missing data and update CSV
fill_missing_data() {
    local csv_file=$1
    local missing_file=$2
    local temp_new_data="$TEMP_DIR/new_data.csv"
    local temp_merged="$TEMP_DIR/merged_data.csv"
    
    local missing_count=$(wc -l < "$missing_file")
    
    if [[ $missing_count -eq 0 ]]; then
        log "No missing data to fill"
        rm -f "$backup_file"
        return 0
    fi
    
    log "Filling $missing_count missing hours..."
    
    # Fetch data for each missing timestamp
    local filled_count=0
    local failed_count=0
    
    > "$temp_new_data"  # Clear the file
    
    while read -r missing_timestamp; do
        if [[ -n "$missing_timestamp" ]]; then
            if new_data=$(fetch_missing_data "$missing_timestamp"); then
                echo "$new_data" >> "$temp_new_data"
                ((filled_count++))
                log "✓ Filled data for $(timestamp_to_date $missing_timestamp)"
            else
                ((failed_count++))
                log "✗ Failed to fill data for $(timestamp_to_date $missing_timestamp)"
            fi
            
            # Small delay to be respectful to the API
            sleep 0.1
        fi
    done < "$missing_file"
    
    log "Successfully filled: $filled_count, Failed: $failed_count"
    
    if [[ $filled_count -gt 0 ]]; then
        # Merge new data with existing data
        log "Merging new data with existing CSV..."
        
        {
            tail -n +2 "$csv_file"  # Existing data without header
            cat "$temp_new_data"    # New data
        } | sort -n -t',' -k3,3 | awk -F',' '!seen[$3]++' > "$temp_merged"
        
        # Write header and merged data back to original file
        echo "hour_start_date,hbar_price_usd,hour_start_timestamp,cent_equivalent,hbar_equivalent" > "$csv_file"
        cat "$temp_merged" >> "$csv_file"
        
        log "Successfully updated CSV file with $filled_count new records"
        
        # Clean up temp files
        rm -f "$temp_new_data" "$temp_merged"
    fi
}

# Main function
main() {
    # Check for help request
    if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
        usage
    fi
    
    # Check for required tools
    command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required but not installed." >&2; exit 1; }
    command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required but not installed." >&2; exit 1; }
    command -v bc >/dev/null 2>&1 || { echo "ERROR: bc is required but not installed." >&2; exit 1; }
    
    # Get CSV file path
    local csv_file=${1:-$DEFAULT_CSV_FILE}
    
    # Validate CSV file exists
    if [[ ! -f "$csv_file" ]]; then
        log "ERROR: CSV file not found: $csv_file"
        exit 1
    fi
    
    # Validate CSV file has the expected header
    local header=$(head -n 1 "$csv_file")
    local expected_header="hour_start_date,hbar_price_usd,hour_start_timestamp,cent_equivalent,hbar_equivalent"
    
    if [[ "$header" != "$expected_header" ]]; then
        log "ERROR: CSV file has unexpected header format"
        log "Expected: $expected_header"
        log "Found: $header"
        exit 1
    fi
    
    log "Starting missing data analysis and filling process"
    log "CSV file: $csv_file"
    
    # Create backup
    local backup_file="${csv_file}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$csv_file" "$backup_file"
    log "Created backup: $backup_file"
    
    # Analyze and find missing hours
    local missing_file
    if missing_file=$(analyze_missing_hours "$csv_file"); then
        # Fill missing data
        fill_missing_data "$csv_file" "$missing_file"
        
        # Clean up
        rm -f "$missing_file"
        rm -f "$backup_file"
          
        log "Process completed successfully"
    else
        log "ERROR: Failed to analyze CSV file"
        exit 1
    fi
}

# Run main function
main "$@"
