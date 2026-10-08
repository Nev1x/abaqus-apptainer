#!/usr/bin/env bash
# Сводка по задачам в RESULTS_DIR:  scripts/status.sh
set -euo pipefail
source "$(dirname "$0")/common.sh"
load_config

[ -d "$RESULTS_DIR" ] || { echo "Каталог результатов пуст: $RESULTS_DIR"; exit 0; }

printf '%-28s %-12s %10s  %s\n' JOB STATUS WALL,s HOST
for d in $(find "$RESULTS_DIR" -mindepth 1 -maxdepth 1 -type d | sort -V); do
    job=$(basename "$d")
    st=$(cat "$d/STATUS" 2>/dev/null || echo "-")
    wall=$(grep -m1 '^wall_seconds=' "$d/job.meta" 2>/dev/null | cut -d= -f2 || true)
    host=$(grep -m1 '^host=' "$d/job.meta" 2>/dev/null | cut -d= -f2 || true)
    # Для идущего расчёта показываем прогресс из .sta (последняя строка с шагом)
    if [ "$st" = RUNNING ] && [ -f "$d/$job.sta" ]; then
        st="RUNNING $(awk 'NF>=4 && $1 ~ /^[0-9]+$/ {last=$2} END {if (last!="") print "t=" last}' "$d/$job.sta")"
    fi
    printf '%-28s %-12s %10s  %s\n' "$job" "$st" "${wall:--}" "${host:--}"
done
echo
for s in DONE RUNNING FAILED INTERRUPTED; do
    printf '%s: %s  ' "$s" "$(cat "$RESULTS_DIR"/*/STATUS 2>/dev/null | grep -cx "$s" || true)"
done
echo
