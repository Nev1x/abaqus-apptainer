#!/usr/bin/env bash
# ШАГ 4. Все задачи серии по очереди + итоговый отчёт.
#
#   opencourant/run_all.sh                    # все inputs/*.inp, по одной задаче на всех ядрах
#   opencourant/run_all.sh inputs/Job-24-12-01-{1..4}.inp   # только выбранные задачи
#   PARALLEL=2 opencourant/run_all.sh         # по 2 задачи одновременно, ядра делятся поровну
#
# Долгий запуск — так, чтобы он пережил закрытие SSH:
#   nohup opencourant/run_all.sh > run_all.log 2>&1 &      (смотреть: tail -f run_all.log)
#
# Повторный запуск продолжает с места остановки: готовые задачи пропускаются.
set -euo pipefail
source "$(dirname "$0")/common.sh"
LOG_TAG=all
load_image

PARALLEL=${PARALLEL:-1}
NP=${NP:-$(( $(ncpu) / PARALLEL ))}
[ "$NP" -ge 1 ] || NP=1
export NP

if [ $# -gt 0 ]; then
    FILES=("$@")
else
    ls "$INPUT_DIR"/*.inp >/dev/null 2>&1 || die "в $INPUT_DIR нет файлов .inp — положите их туда (README, шаг 2)"
    FILES=($(ls "$INPUT_DIR"/*.inp | sort -V))
fi
N=${#FILES[@]}
log "задач: $N; одновременно: $PARALLEL по $NP ядер"

# Очередь: не больше PARALLEL задач одновременно (чистый bash, без xargs/parallel)
rc=0
for inp in "${FILES[@]}"; do
    while [ "$(jobs -rp | wc -l)" -ge "$PARALLEL" ]; do wait -n || rc=1; done
    "$PROJECT_DIR/opencourant/run_job.sh" "$inp" &
done
while [ "$(jobs -rp | wc -l)" -gt 0 ]; do wait -n || rc=1; done

"$PROJECT_DIR/opencourant/status.sh"
oc python3 "$PROJECT_DIR/opencourant/report.py" "$RESULTS_DIR" "$PROJECT_DIR/report"
[ $rc -eq 0 ] || die "есть задачи с ошибками (FAILED) — см. results/<задача>/*.log и запустите run_all.sh снова"
log "все задачи рассчитаны; отчёт: $PROJECT_DIR/report/"
