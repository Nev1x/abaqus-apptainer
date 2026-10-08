#!/usr/bin/env bash
# Отправка всех задач в Slurm одним массивом.
#
#   scripts/slurm/submit.sh                 # все *.inp из INPUT_DIR, не более 4 одновременно
#   MAX_PARALLEL=8 scripts/slurm/submit.sh inputs/
#
# Уже рассчитанные задачи (STATUS=DONE) в список не попадают, поэтому после сбоя
# достаточно запустить submit.sh ещё раз.
set -euo pipefail
source "$(dirname "$0")/../common.sh"
load_config
cd "$PROJECT_DIR"

DIR=${1:-$INPUT_DIR}
: > jobs.list
for f in $(find "$DIR" -maxdepth 1 -name '*.inp' -type f | sort -V); do
    job=$(basename "$f" .inp)
    [ "$(cat "$RESULTS_DIR/$job/STATUS" 2>/dev/null)" = DONE ] && continue
    printf '%s\n' "$f" >> jobs.list
done
N=$(wc -l < jobs.list | tr -d ' ')
[ "$N" -gt 0 ] || { echo "нечего считать: все задачи из $DIR уже DONE"; exit 0; }

mkdir -p logs
# %MAX_PARALLEL ограничивает число одновременно идущих элементов массива (лицензии!)
sbatch --array="1-$N%${MAX_PARALLEL:-4}" scripts/slurm/abaqus_array.sbatch
echo "отправлено задач: $N (список: jobs.list). Состояние: squeue -u \$USER; scripts/status.sh"
