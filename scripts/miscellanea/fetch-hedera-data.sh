#!/bin/bash

# HBAR Price Fetcher Script
# Fetches hourly HBAR exchange rates from Hedera Mirror Node API
# Usage: ./fetch-hedera-oracle-prices.sh [start_timestamp] [end_timestamp]

set -euo pipefail

# Configuration
readonly SCRIPT_DIR=$(dirname "$0")
readonly BASE_DIR="$SCRIPT_DIR/.."
readonly EXISTING_DATA_FILE="$BASE_DIR/data/hedera-hbar-prices.csv"
readonly OUTPUT_FILE="$BASE_DIR/build/data/hedera-hbar-prices.csv"
readonly API_BASE_URL="https://mainnet.mirrornode.hedera.com/api/v1/network/exchangerate"
readonly FALLBACK_START_TIMESTAMP=1568584800 # Fallback start timestamp (2019-09-15 22:00:00 UTC)

# Create directories if they don't exist
mkdir -p "$BASE_DIR/build/data"

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
    echo "[$(date '+%Y-%m-%d %H:%M:%S:%N')] $1" >&2
}

# Function to convert timestamp to human readable date
timestamp_to_date() {
    date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ'
}

# Function to round timestamp down to the nearest hour
round_to_hour() {
    local timestamp=$1
    echo $((timestamp - (timestamp % 3600)))
}

# Function to get the last timestamp from existing data file
get_last_timestamp() {
    if [[ -f "$EXISTING_DATA_FILE" ]]; then
        # Get the last line, extract the third field (timestamp), and validate it's numeric
        local last_timestamp=$(tail -n 1 "$EXISTING_DATA_FILE" | cut -d',' -f3)
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

# Function to check if data collection is up to date
check_data_up_to_date() {
    local start_timestamp=$1
    local current_time=$(date +%s)
    
    if [[ $start_timestamp -gt $current_time && -f "$EXISTING_DATA_FILE" ]]; then
        local last_timestamp=$(tail -n 1 "$EXISTING_DATA_FILE" | cut -d',' -f3)
        if [[ "$last_timestamp" =~ ^[0-9]+$ ]]; then
            local last_date=$(timestamp_to_date "$last_timestamp")
            local next_date=$(timestamp_to_date "$start_timestamp")
            local current_date=$(timestamp_to_date "$current_time")
            
            log "INFO: Data collection is up to date."
            log "Last recorded data: $last_date (timestamp: $last_timestamp)"
            log "Next collection time: $next_date (timestamp: $start_timestamp)"
            log "Current time: $current_date (timestamp: $current_time)"
            log "No new data to collect at this time."
            exit 0
        fi
    fi
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
    
    # Extract current_rate and next_rate using basic JSON parsing
    local current_cent=$(echo "$response" | jq -r ".current_rate.cent_equivalent")
    local current_hbar=$(echo "$response" | jq -r ".current_rate.hbar_equivalent")
    local current_expiration=$(echo "$response" | jq -r ".current_rate.expiration_time")
    
    local next_cent=$(echo "$response" | jq -r ".next_rate.cent_equivalent")
    local next_hbar=$(echo "$response" | jq -r ".next_rate.hbar_equivalent")
    local next_expiration=$(echo "$response" | jq -r ".next_rate.expiration_time")
    
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
   
    echo "$(timestamp_to_date $current_hour_start),$current_price,$current_hour_start,$current_cent,$current_hbar" >> "$OUTPUT_FILE"
    echo "$(timestamp_to_date $next_hour_start),$next_price,$next_hour_start,$next_cent,$next_hbar" >> "$OUTPUT_FILE"

    return 0
}

# Function to initialize CSV file
init_csv() {
    echo "hour_start_date,hbar_price_usd,hour_start_timestamp,cent_equivalent,hbar_equivalent" > "$OUTPUT_FILE"
    log "Initialized CSV file: $OUTPUT_FILE"
}

# Main function
main() {
    # Check for help request
    if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
        usage
    fi
    
    # Check for required tools
    command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required but not installed." >&2; exit 1; }
    command -v bc >/dev/null 2>&1 || { echo "ERROR: bc is required but not installed." >&2; exit 1; }
    
    # Parse arguments and make them global
    local default_start_timestamp=$(get_last_timestamp)
    local raw_start_timestamp=${1:-$default_start_timestamp}
    local raw_end_timestamp=${2:-$(date +%s)}
    
    # Check if data collection is up to date (only when using default start timestamp)
    if [[ -z "${1:-}" ]]; then
        check_data_up_to_date "$raw_start_timestamp"
    fi
    
    # Round timestamps to exact hours
    START_TIMESTAMP=$(round_to_hour "$raw_start_timestamp")
    END_TIMESTAMP=$(round_to_hour "$raw_end_timestamp")
    
    # If the end timestamp was rounded down and it's the same as start, add one hour
    if [[ $START_TIMESTAMP -eq $END_TIMESTAMP ]]; then
        END_TIMESTAMP=$((END_TIMESTAMP + 3600))
    fi
    
    # Validate timestamps
    if ! [[ "$START_TIMESTAMP" =~ ^[0-9]+$ ]] || ! [[ "$END_TIMESTAMP" =~ ^[0-9]+$ ]]; then
        log "ERROR: Timestamps must be numeric"
        usage
    fi
    
    if [[ $START_TIMESTAMP -ge $END_TIMESTAMP ]]; then
        log "ERROR: Start timestamp must be less than end timestamp"
        usage
    fi
    
    log "Starting HBAR price collection"
    log "Default start timestamp: $default_start_timestamp ($(timestamp_to_date "$default_start_timestamp"))"
    log "Raw start: $(timestamp_to_date "$raw_start_timestamp"), rounded to: $(timestamp_to_date $START_TIMESTAMP)"
    log "Raw end: $(timestamp_to_date "$raw_end_timestamp"), rounded to: $(timestamp_to_date $END_TIMESTAMP)"
    
    # Initialize CSV file
    init_csv
    
    # Start from the start timestamp and work forward
    local current_timestamp=$START_TIMESTAMP
    local processed_requests=0
    local failed_requests=0
    
    # Calculate total time span for progress reporting
    local total_seconds=$((END_TIMESTAMP - START_TIMESTAMP))
    local total_days=$((total_seconds / 86400))
    log "Processing approximately $total_days days of data..."
    log "Starting from timestamp: $current_timestamp ($(timestamp_to_date $current_timestamp))"
    
    # Process in chunks to be efficient
    while [[ $current_timestamp -lt $END_TIMESTAMP ]]; do
        # Query for a timestamp to get rates that include our current_timestamp period
        local query_timestamp=$((current_timestamp + 7200))  # Look 2 hours ahead
        
        # Don't exceed our end timestamp
        if [[ $query_timestamp -gt $END_TIMESTAMP ]]; then
            query_timestamp=$END_TIMESTAMP
        fi
        
        # log "Querying API for timestamp: $query_timestamp ($(timestamp_to_date $query_timestamp))"
    
        if response=$(make_api_request "$query_timestamp"); then
            if parse_response "$response" "$query_timestamp"; then
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
            local current_records=$(($(wc -l < "$OUTPUT_FILE") - 1))
            log "Progress: $processed_requests requests completed, $current_records records saved, currently at: $progress_date"
        fi
        
        # # Safety check to prevent infinite loops  
        # if [[ $processed_requests -gt 50000 ]]; then
        #     log "WARNING: Processed over 50000 requests, stopping"
        #     break
        # fi
    done
    
    local total_records=$(($(wc -l < "$OUTPUT_FILE") - 1))
    
    log "Collection completed!"
    log "Total requests: $processed_requests"
    log "Failed requests: $failed_requests"
    log "Total records saved: $total_records"
    log "Output file: $OUTPUT_FILE"
    
    # if [[ $total_records -gt 0 ]]; then
    #     log "First few records:"
    #     head -5 "$OUTPUT_FILE" >&2
    # fi

    # Merging new data with existing data
    cat $OUTPUT_FILE $EXISTING_DATA_FILE |\
        awk '!seen[$0]++' |\
        sort -n > $OUTPUT_FILE.tmp
    cat $OUTPUT_FILE.tmp > $EXISTING_DATA_FILE
    rm -f $OUTPUT_FILE.tmp

    # Fill potentially missing data
    $SCRIPT_DIR/fill-missing-hedera-data.sh
}

# Run main function
main "$@"