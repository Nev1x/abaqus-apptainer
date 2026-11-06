#!/usr/bin/env bash
# Пересобрать отчёт report/ по уже рассчитанным задачам:  opencourant/report.sh
set -euo pipefail
source "$(dirname "$0")/common.sh"
load_image
oc python3 "$PROJECT_DIR/opencourant/report.py" "$RESULTS_DIR" "$PROJECT_DIR/report"
