#!/bin/bash

# HBAR Price Fetcher and Gap Filler Script
# Fetches hourly HBAR exchange rates from Hedera Mirror Node API and fills any missing data
# Usage: ./fetch-and-fill-hedera-data.sh [start_timestamp] [end_timestamp]

set -euo pipefail

# Configuration
readonly SCRIPT_DIR=$(dirname "$0")
readonly BASE_DIR="$SCRIPT_DIR/.."
readonly EXISTING_DATA_FILE="$BASE_DIR/data/hedera-hbar-prices.csv"
readonly API_BASE_URL="https://mainnet.mirrornode.hedera.com/api/v1/network/exchangerate"
readonly FALLBACK_START_TIMESTAMP=$(($(date +%s) - 864000)) # Fallback start timestamp (10 days ago)

# Create directories if they don't exist
mkdir -p "$BASE_DIR/data"

# Function to display usage
usage() {
    echo "Usage: $0 [start_timestamp] [end_timestamp]"
    echo "  start_timestamp: Unix timestamp to start from (default: last timestamp from existing data or $FALLBACK_START_TIMESTAMP)"
    echo "  end_timestamp: Unix timestamp to end at (default: current time)"
    echo "Example: $0 1568584800 1568671200"
    exit 1
}

# Function to log messages with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S:%N')] HEDERA - $1" >&2
}

# Function to convert timestamp to human readable date
timestamp_to_date() {
    local timestamp=${1:-0}
    if [[ -z "$timestamp" || "$timestamp" == "0" ]]; then
        echo "INVALID_TIMESTAMP"
        return 1
    fi
    # macOS/BSD date first, then GNU date as fallback
    date -u -r "$timestamp" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$timestamp" '+%Y-%m-%dT%H:%M:%SZ'
}

# Function to round timestamp down to the nearest hour
round_to_hour() {
    local timestamp=$1
    echo $((timestamp - (timestamp % 3600)))
}

# Function to get the last timestamp from existing data file
get_last_timestamp() {
    if [[ -f "$EXISTING_DATA_FILE" ]]; then
        # Get the last non-empty line, extract the third field (timestamp), and validate it's numeric
        local last_timestamp=$(grep -v '^$' "$EXISTING_DATA_FILE" | tail -n 1 | cut -d',' -f3)
        if [[ "$last_timestamp" =~ ^[0-9]+$ ]]; then
            # Add one hour (3600 seconds) to start from the next hour after the last recorded data
            local next_timestamp=$((last_timestamp + 3600))
            echo "$next_timestamp"
            return 0
        else
            log "WARNING: Could not parse timestamp from existing data file, using fallback"
        fi
    else
        log "INFO: Existing data file not found, using fallback timestamp"
    fi
    echo "$FALLBACK_START_TIMESTAMP"
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

# Function to parse JSON response and extract rates
parse_response() {
    local response=$1
    local timestamp=$2
    local temp_output_file=$3
    
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
        log "ERROR: Failed to parse response for timestamp $timestamp"
        return 1
    fi
    
    # Calculate prices
    local current_price=$(calculate_hbar_price "$current_cent" "$current_hbar")
    local next_price=$(calculate_hbar_price "$next_cent" "$next_hbar")
        
    # Current rate (the hour ending at current_expiration)
    local current_hour_start=$((current_expiration - 3600))
   
    # Next rate (the hour ending at next_expiration)
    local next_hour_start=$((next_expiration - 3600))
   
    echo "$(timestamp_to_date $current_hour_start),$current_price,$current_hour_start,$current_cent,$current_hbar" >> "$temp_output_file"
    echo "$(timestamp_to_date $next_hour_start),$next_price,$next_hour_start,$next_cent,$next_hbar" >> "$temp_output_file"

    return 0
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

# Function to initialize CSV file
init_csv() {
    local temp_output_file=$1
    echo "hour_start_date,hbar_price_usd,hour_start_timestamp,cent_equivalent,hbar_equivalent" > "$temp_output_file"
    log "Initialized temporary CSV file: $temp_output_file"
}

# Function to merge and deduplicate data
merge_and_deduplicate() {
    local temp_fetch_file=$1
    local temp_merged=$(mktemp)
    
    # Merge new data with existing data, preserving header
    {
        # First, write the header
        echo "hour_start_date,hbar_price_usd,hour_start_timestamp,cent_equivalent,hbar_equivalent"
        
        # Then merge data without headers and sort by timestamp (3rd field)
        {
            tail -n +2 "$temp_fetch_file" 2>/dev/null || true   # New data without header
            tail -n +2 "$EXISTING_DATA_FILE" 2>/dev/null || true  # Existing data without header
        } | awk -F',' '!seen[$3]++' | sort -n -t',' -k3,3
        
    } > "$temp_merged"
    
    # Replace the existing file
    cat "$temp_merged" > "$EXISTING_DATA_FILE"
    rm -f "$temp_merged"
}

# Function to analyze CSV and find missing hours
analyze_missing_hours() {
    local csv_file=$1
    local temp_missing=$(mktemp)
    
    log "Analyzing CSV file for missing hours: $csv_file"
    
    # Extract all timestamps from the CSV (skip header)
    local existing_timestamps=$(tail -n +2 "$csv_file" | cut -d',' -f3 | grep '^[0-9]\+$' | sort -n)
    
    if [[ -z "$existing_timestamps" ]]; then
        log "WARNING: No valid timestamp data found in CSV file"
        > "$temp_missing"  # Create empty file
        echo "$temp_missing"
        return 0
    fi
    
    # Get the range of timestamps
    local first_timestamp=$(echo "$existing_timestamps" | head -n 1)
    local last_timestamp=$(echo "$existing_timestamps" | tail -n 1)
    
    # Validate timestamps
    if [[ -z "$first_timestamp" || -z "$last_timestamp" ]]; then
        log "WARNING: Could not determine timestamp range"
        > "$temp_missing"  # Create empty file
        echo "$temp_missing"
        return 0
    fi
    
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
    local temp_new_data=$(mktemp)
    local temp_merged=$(mktemp)

    local missing_count=$(wc -l < "$missing_file" | awk '{print $1}')

    if [[ $missing_count -eq 0 ]]; then
        log "No missing data to fill"
        rm -f "$temp_new_data" "$temp_merged"
        return 0
    fi

    log "Filling $missing_count missing hour$([ $missing_count -gt 1 ] && echo -n s)..."

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
    fi
    
    # Clean up temp files
    rm -f "$temp_new_data" "$temp_merged"
}

# Function to perform initial data fetch
perform_initial_fetch() {
    local start_timestamp=$1
    local end_timestamp=$2
    local temp_output_file=$(mktemp)
    
    log "Starting HBAR price collection"
    log "Start: $(timestamp_to_date $start_timestamp), End: $(timestamp_to_date $end_timestamp)"
    
    # Initialize CSV file
    init_csv "$temp_output_file"
    
    # Start from the start timestamp and work forward
    local current_timestamp=$start_timestamp
    local processed_requests=0
    local failed_requests=0
    
    # Calculate total time span for progress reporting
    local total_seconds=$((end_timestamp - start_timestamp))
    local total_days=$((total_seconds / 86400))
    log "Processing approximately $total_days days of data..."
    log "Starting from timestamp: $current_timestamp ($(timestamp_to_date $current_timestamp))"
    
    # Process in chunks to be efficient
    while [[ $current_timestamp -lt $end_timestamp ]]; do
        # Query for a timestamp to get rates that include our current_timestamp period
        local query_timestamp=$((current_timestamp + 7200))  # Look 2 hours ahead
        
        # Don't exceed our end timestamp
        if [[ $query_timestamp -gt $end_timestamp ]]; then
            query_timestamp=$end_timestamp
        fi
    
        if response=$(make_api_request "$query_timestamp"); then
            if parse_response "$response" "$query_timestamp" "$temp_output_file"; then
                ((processed_requests += 1))
            else
                ((failed_requests++))
            fi
        else
            ((failed_requests++))
        fi
        
        # Move forward by 2 hours
        current_timestamp=$((current_timestamp + 7200))
        
        # Progress update every 100 requests
        if (( processed_requests % 100 == 0 )) && (( processed_requests > 0 )); then
            local progress_date=$(timestamp_to_date $current_timestamp)
            local current_records=$(($(wc -l < "$temp_output_file") - 1))
            log "Progress: $processed_requests requests completed, $current_records records saved, currently at: $progress_date"
        fi
    done
    
    local total_records=$(($(wc -l < "$temp_output_file") - 1))
    
    log "Initial collection completed!"
    log "Total requests: $processed_requests"
    log "Failed requests: $failed_requests"
    log "Total records saved: $total_records"
    
    # Merge new data with existing data
    merge_and_deduplicate "$temp_output_file"
    
    # Clean up temporary fetch file
    rm -f "$temp_output_file"
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
    
    # Parse arguments
    local default_start_timestamp=$(get_last_timestamp)
    local raw_start_timestamp=${1:-$default_start_timestamp}
    local raw_end_timestamp=${2:-$(date +%s)}
    
    # Round timestamps to exact hours
    local start_timestamp=$(round_to_hour "$raw_start_timestamp")
    local end_timestamp=$(round_to_hour "$raw_end_timestamp")
    
    # If the start timestamp is in the future, don't fetch anything
    local current_time=$(date +%s)
    if [[ $start_timestamp -gt $current_time ]]; then
        log "INFO: Next data collection time is in the future ($(timestamp_to_date $start_timestamp))"
        log "Current time: $(timestamp_to_date $current_time)"
        log "Skipping data fetch, proceeding to gap filling only"
    else
        # If the end timestamp was rounded down and it's the same as start, add one hour
        if [[ $start_timestamp -ge $end_timestamp ]]; then
            end_timestamp=$((start_timestamp + 3600))
        fi
        
        # Validate timestamps
        if ! [[ "$start_timestamp" =~ ^[0-9]+$ ]] || ! [[ "$end_timestamp" =~ ^[0-9]+$ ]]; then
            log "ERROR: Timestamps must be numeric"
            usage
        fi
        
        # Perform initial data fetch
        perform_initial_fetch "$start_timestamp" "$end_timestamp"
    fi
    
    # Now check for and fill missing data
    if [[ -f "$EXISTING_DATA_FILE" ]]; then
        # Validate CSV file has the expected header
        local header=$(head -n 1 "$EXISTING_DATA_FILE")
        local expected_header="hour_start_date,hbar_price_usd,hour_start_timestamp,cent_equivalent,hbar_equivalent"
        
        if [[ "$header" != "$expected_header" ]]; then
            log "ERROR: CSV file has unexpected header format"
            log "Expected: $expected_header"
            log "Found: $header"
            exit 1
        fi
        
        log "Starting missing data analysis and filling process"
        log "CSV file: $EXISTING_DATA_FILE"
        
        # Create backup using mktemp
        local backup_file=$(mktemp)
        cp "$EXISTING_DATA_FILE" "$backup_file"
        log "Created temporary backup: $backup_file"
        
        # Analyze and find missing hours
        local missing_file
        if missing_file=$(analyze_missing_hours "$EXISTING_DATA_FILE"); then
            # Fill missing data
            fill_missing_data "$EXISTING_DATA_FILE" "$missing_file"
            
            # Clean up
            rm -f "$missing_file"
            rm -f "$backup_file"
              
            log "Process completed successfully"
        else
            log "ERROR: Failed to analyze CSV file"
            # Restore from backup if something went wrong
            cp "$backup_file" "$EXISTING_DATA_FILE"
            rm -f "$backup_file"
            exit 1
        fi
    else
        log "WARNING: No existing data file found to check for missing data"
    fi
}

# Run main function
main "$@"
