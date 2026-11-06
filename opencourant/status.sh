#!/usr/bin/env bash
# Состояние задач:  opencourant/status.sh
set -euo pipefail
source "$(dirname "$0")/common.sh"

[ -d "$RESULTS_DIR" ] || { echo "Пока ничего не считалось ($RESULTS_DIR нет)"; exit 0; }
# заголовок выровнен вручную: printf считает ширину в байтах, а русская буква — 2 байта
echo 'ЗАДАЧА               СТАТУС     ВРЕМЯ,с    ШАГОВ'
for d in $(ls -d "$RESULTS_DIR"/*/ 2>/dev/null | sort -V); do
    job=$(basename "$d")
    st=$(cat "$d/STATUS" 2>/dev/null || echo -)
    meta() { grep -m1 "^$1=" "$d/job.meta" 2>/dev/null | cut -d= -f2 || true; }
    if [ "$st" = RUNNING ] && [ -f "$d/engine.log" ]; then
        # строка журнала: " NC= 9300 T= 2.35E-01 DT= 2.52E-05 ..." — берём модельное время T (не DT)
        st="идёт $(grep -o ' T= [0-9.E+-]*' "$d/engine.log" | tail -n1 | awk '{printf "t=%.2f", $2}')"
    fi
    printf '%-20s %-9s %8s %8s\n' "$job" "$st" "$(meta wall_seconds)" "$(meta cycles)"
done
echo
for s in DONE RUNNING FAILED; do
    printf '%s: %s   ' "$s" "$(cat "$RESULTS_DIR"/*/STATUS 2>/dev/null | grep -cx "$s" || true)"
done
echo
