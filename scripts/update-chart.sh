#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR=$(dirname "$0")

mkdir -p ./build

$SCRIPT_DIR/fetch-cmc-data.sh
$SCRIPT_DIR/fetch-and-check-hedera-data.sh
$SCRIPT_DIR/merge-and-fill-csv-data.sh
$SCRIPT_DIR/write-data-and-release-chart.sh
