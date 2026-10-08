#!/usr/bin/env bash
# Очередь расчётов на одном сервере: выполняет все *.inp, не более PARALLEL одновременно.
#
#   scripts/run_queue.sh                    # все *.inp из INPUT_DIR (config.env)
#   scripts/run_queue.sh inputs/            # все *.inp из каталога
#   scripts/run_queue.sh a.inp b.inp        # выбранные задачи
#
# Долгий запуск — в tmux/screen или так:
#   nohup scripts/run_queue.sh > queue.log 2>&1 &
#
# Повторный запуск продолжает с места остановки: задачи со статусом DONE пропускаются,
# FAILED и INTERRUPTED считаются заново.
set -euo pipefail
source "$(dirname "$0")/common.sh"
load_config
LOG_TAG=queue

# --- Список задач -------------------------------------------------------------
[ $# -gt 0 ] || set -- "$INPUT_DIR"
LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT
for a in "$@"; do
    if [ -d "$a" ]; then
        find "$a" -maxdepth 1 -name '*.inp' -type f
    elif [ -f "$a" ]; then
        printf '%s\n' "$a"
    else
        log "нет такого файла или каталога: $a"; exit 2
    fi
done | sort -V > "$LIST"
N=$(grep -c . "$LIST" || true)
[ "$N" -gt 0 ] || { log "не найдено ни одного .inp"; exit 2; }

# --- Ресурсы ------------------------------------------------------------------
CORES=$(ncpu)
if [ -z "${PARALLEL:-}" ]; then
    PARALLEL=$(( CORES / CPUS ))
    [ "$PARALLEL" -ge 1 ] || PARALLEL=1
fi
if [ -z "${MEMORY:-}" ]; then
    MEMORY="$(( 90 / PARALLEL ))%"
fi
export PARALLEL MEMORY
# Токены лицензии Abaqus на задачу: int(5 * N^0.422), N — число ядер
TOKENS=$(awk -v n="$CPUS" -v p="$PARALLEL" 'BEGIN { t = int(5 * n ^ 0.422); print t " на задачу, " t * p " всего" }')

if [ "$RUNTIME" = apptainer ] || [ "$RUNTIME" = singularity ]; then
    command -v "$RUNTIME" >/dev/null || { log "не найдена команда $RUNTIME"; exit 2; }
    [ -e "$SIF" ] || { log "нет образа $SIF (см. README, раздел 3)"; exit 2; }
fi
if [ $(( PARALLEL * CPUS )) -gt "$CORES" ]; then
    log "ВНИМАНИЕ: PARALLEL*CPUS = $(( PARALLEL * CPUS )) больше числа ядер ($CORES) — расчёты будут мешать друг другу"
fi

DONE_BEFORE=$(cd "$RESULTS_DIR" 2>/dev/null && grep -lx DONE ./*/STATUS 2>/dev/null | wc -l | tr -d ' ' || echo 0)
log "задач: $N (уже готово: $DONE_BEFORE); одновременно: $PARALLEL x $CPUS ядер (на сервере $CORES);" \
    "память на задачу: $MEMORY; токены: $TOKENS; среда: $RUNTIME"
log "результаты: $RESULTS_DIR"

# --- Запуск -------------------------------------------------------------------
# xargs -P держит не более PARALLEL задач; ошибка одной задачи не останавливает остальные.
rc=0
tr '\n' '\0' < "$LIST" | xargs -0 -n 1 -P "$PARALLEL" "$PROJECT_DIR/scripts/run_job.sh" || rc=$?

"$PROJECT_DIR/scripts/status.sh" || true
if [ $rc -ne 0 ]; then
    log "есть задачи с ошибками — исправьте причину и запустите очередь повторно"
    exit 1
fi
log "все задачи выполнены"
