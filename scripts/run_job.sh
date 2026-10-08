#!/usr/bin/env bash
# Расчёт одной задачи Abaqus в контейнере.
#
#   scripts/run_job.sh inputs/Job-24-12-01-1.inp
#
# Результат: каталог $RESULTS_DIR/<JOB>/ с файлами Abaqus и служебными файлами:
#   STATUS        RUNNING | DONE | FAILED | INTERRUPTED
#   job.meta      параметры запуска, время, хост, контрольная сумма .inp
#   run.out       вывод команды abaqus
#   <JOB>_history.csv  история U3/RF3 (если POSTPROCESS=1)
#
# Повторный запуск задачи со статусом DONE пропускается (FORCE=1 — пересчитать).
# Одновременный запуск одной задачи из двух процессов исключён блокировкой.
set -euo pipefail
source "$(dirname "$0")/common.sh"
load_config

[ $# -eq 1 ] || { echo "Использование: $0 <файл.inp>" >&2; exit 2; }
INP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
[ -f "$INP" ] || { echo "Нет файла: $1" >&2; exit 2; }
JOB=$(basename "$INP" .inp)
LOG_TAG=$JOB
RUN_DIR="$RESULTS_DIR/$JOB"
STATUS_FILE="$RUN_DIR/STATUS"
META="$RUN_DIR/job.meta"
mkdir -p "$RUN_DIR"

if [ "${FORCE:-0}" != 1 ] && [ "$(cat "$STATUS_FILE" 2>/dev/null)" = DONE ]; then
    log "уже рассчитана, пропуск"
    exit 0
fi

# --- Блокировка: mkdir атомарен, в т.ч. на NFS -------------------------------
LOCK="$RUN_DIR/.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    owner=$(cat "$LOCK/owner" 2>/dev/null || true)
    if [ "${owner%%:*}" = "$(hostname)" ] && ! kill -0 "${owner##*:}" 2>/dev/null; then
        log "снимаю устаревшую блокировку ($owner)"
        rm -rf "$LOCK"; mkdir "$LOCK"
    else
        log "уже выполняется другим процессом ($owner), пропуск"
        exit 0
    fi
fi
echo "$(hostname):$$" > "$LOCK/owner"

child=
finish() {
    local st=$1
    echo "$st" > "$STATUS_FILE"
    echo "status=$st" >> "$META"
    echo "end=$(date '+%Y-%m-%dT%H:%M:%S')" >> "$META"
    rm -rf "$LOCK"
}
on_signal() {
    log "получен сигнал, останавливаю расчёт"
    if [ -n "$child" ]; then
        # Штатная остановка Abaqus, затем вся группа процессов задачи (решатель,
        # дочерние процессы контейнера). Через 20 с — принудительно.
        abq_exec "$RUN_DIR" terminate job="$JOB" >> "$RUN_DIR/run.out" 2>&1 || true
        kill -TERM -- "-$child" 2>/dev/null || true
        for _ in $(seq 20); do
            kill -0 -- "-$child" 2>/dev/null || break
            sleep 1
        done
        kill -KILL -- "-$child" 2>/dev/null || true
    fi
    finish INTERRUPTED
    exit 130
}
trap on_signal INT TERM

# --- Подготовка --------------------------------------------------------------
[ "$INP" = "$RUN_DIR/$JOB.inp" ] || cp "$INP" "$RUN_DIR/$JOB.inp"
rm -f "$RUN_DIR/$JOB.lck"   # остаётся после аварийно прерванного расчёта
MEM=${MEMORY:-90%}

args=(job="$JOB" input="$JOB.inp" cpus="$CPUS" mp_mode="$MP_MODE" memory="$MEM"
      scratch="$(scratch_path)" interactive ask_delete=OFF)
[ "$PRECISION" = double ] && args+=(double=both)

inp_sha=$( (sha256sum "$RUN_DIR/$JOB.inp" 2>/dev/null || shasum -a 256 "$RUN_DIR/$JOB.inp") | cut -d' ' -f1)
case "$RUNTIME" in
    apptainer|singularity) image="$SIF ($(ls -l "$SIF" 2>/dev/null | awk '{print $5" bytes, "$6" "$7" "$8}'))" ;;
    docker) image="$DOCKER_IMAGE ($(docker image inspect -f '{{.Id}}' "$DOCKER_IMAGE" 2>/dev/null || echo '?'))" ;;
    *) image=native ;;
esac
cat > "$META" <<EOF
job=$JOB
host=$(hostname)
runtime=$RUNTIME
image=$image
inp_sha256=$inp_sha
cmd=$ABAQUS_CMD ${args[*]}
start=$(date '+%Y-%m-%dT%H:%M:%S')
EOF
echo RUNNING > "$STATUS_FILE"

# --- Расчёт ------------------------------------------------------------------
log "старт: ${args[*]}"
t0=$(date +%s)
# set -m: задача получает собственную группу процессов, чтобы при остановке
# завершить её целиком и не оставить "осиротевший" решатель.
set -m
abq_exec "$RUN_DIR" "${args[@]}" > "$RUN_DIR/run.out" 2>&1 &
child=$!
set +m
rc=0
wait "$child" || rc=$?
child=
wall=$(( $(date +%s) - t0 ))
echo "exit_code=$rc" >> "$META"
echo "wall_seconds=$wall" >> "$META"

# Код возврата abaqus не всегда отражает ошибку решателя — проверяем и файлы задачи.
ok=1
[ "$rc" -eq 0 ] || ok=0
grep -q "Abaqus JOB $JOB COMPLETED" "$RUN_DIR/$JOB.log" 2>/dev/null || ok=0
grep -q "THE ANALYSIS HAS COMPLETED SUCCESSFULLY" "$RUN_DIR/$JOB.sta" 2>/dev/null || ok=0

if [ $ok -ne 1 ]; then
    log "ОШИБКА (код $rc, ${wall} с). Последние строки журнала:"
    tail -n 15 "$RUN_DIR/$JOB.log" "$RUN_DIR/run.out" 2>/dev/null | sed 's/^/    /' >&2 || true
    grep -h -A4 "\*\*\*ERROR" "$RUN_DIR/$JOB.msg" "$RUN_DIR/$JOB.dat" 2>/dev/null | head -n 20 | sed 's/^/    /' >&2 || true
    finish FAILED
    exit 1
fi
log "расчёт завершён за ${wall} с"

# --- После расчёта -----------------------------------------------------------
if [ "$KEEP_RESTART" != 1 ]; then
    for ext in abq pac res sel stt mdl prt; do rm -f "$RUN_DIR/$JOB.$ext"; done
fi

if [ "$POSTPROCESS" = 1 ]; then
    if abq_exec "$RUN_DIR" python "$(project_path)/abaqus_scripts/extract_history.py" "$JOB.odb" \
            >> "$RUN_DIR/run.out" 2>&1; then
        echo "postprocess=ok" >> "$META"
    else
        echo "postprocess=failed" >> "$META"
        log "предупреждение: постобработка не удалась, см. run.out (расчёт при этом успешен)"
    fi
fi

finish DONE
log "готово"
