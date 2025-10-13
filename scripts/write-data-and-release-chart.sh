#!/bin/bash

# fill-chart-data.sh - Simple script to compress CSV and update HTML
set -e

# Get paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CSV_FILE="$PROJECT_ROOT/build/uncompressed-hbar-prices.csv"
HTML_FILE="$PROJECT_ROOT/src/index.html"
DEST_FILE="$PROJECT_ROOT/release/index.html"

# Check if CSV file exists
if [[ ! -f "$CSV_FILE" ]]; then
    echo "ERROR: CSV file not found: $CSV_FILE"
    exit 1
fi

# Compress file and encode to base64
echo -n "[$(date '+%Y-%m-%d %H:%M:%S:%N')] WRITER - Compressing CSV data..."
COMPRESSED_DATA=$(gzip -c "$CSV_FILE" | base64 -w 0)

if [[ -z "$COMPRESSED_DATA" ]]; then
    echo "ERROR: Compression failed"
    exit 1
fi
echo "Done."

# Update HTML file
echo -n "[$(date '+%Y-%m-%d %H:%M:%S:%N')] WRITER - Updating HTML file..."
TEMP_FILE=$(mktemp)
cp $HTML_FILE $TEMP_FILE

# Escape sed meaningful characters
ESCAPED_REPLACE=$(printf '%s\n' "$COMPRESSED_DATA" | sed -e 's/[\/&]/\\&/g')

# Replace the compressedCsvData line (it cannot be done in the command line anymore because the content became too long)
sed -i -f - "$TEMP_FILE" << EOF
s/compressedCsvData: "[^\"]*"/compressedCsvData: "$ESCAPED_REPLACE"/
EOF

# Move temp file to the release folder
mkdir -p "$PROJECT_ROOT/release/contrib"
mv "$TEMP_FILE" "$DEST_FILE"

# Copy the css and all js files in the contrib folder
cp "$PROJECT_ROOT/src/index.css" "$PROJECT_ROOT/release/" 2>/dev/null
cp -R "$PROJECT_ROOT/src/contrib" "$PROJECT_ROOT/release/"
echo "Done."
