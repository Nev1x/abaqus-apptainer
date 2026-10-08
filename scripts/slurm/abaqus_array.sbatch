#!/bin/bash
# Массив задач Slurm: один элемент массива = одна задача Abaqus (строка из jobs.list).
# Обычно отправляется через scripts/slurm/submit.sh, который сам задаёт --array.
#
# Ресурсы ниже — под исходные задачи 24-12-01 (20 ядер, ~45 мин на задачу при 20 ядрах).
# Поправьте --partition, --mem и --time под свой кластер.
#SBATCH --job-name=abaqus
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=20
#SBATCH --mem=64G
#SBATCH --time=24:00:00
#SBATCH --output=logs/%x_%A_%a.out
# Если на кластере настроен учёт лицензий Abaqus (17 токенов на 20 ядер):
##SBATCH --licenses=abaqus:17

set -euo pipefail
# Slurm запускает копию скрипта из своего каталога — корень проекта берём из окружения
cd "${SLURM_SUBMIT_DIR:?}"

LIST=${JOB_LIST:-jobs.list}
INP=$(sed -n "${SLURM_ARRAY_TASK_ID}p" "$LIST")
[ -n "$INP" ] || { echo "нет строки ${SLURM_ARRAY_TASK_ID} в $LIST" >&2; exit 2; }

# Ядра и память выделены Slurm — передаём их Abaqus
export CPUS=$SLURM_CPUS_PER_TASK
if [ -n "${SLURM_MEM_PER_NODE:-}" ]; then
    export MEMORY="$(( SLURM_MEM_PER_NODE * 9 / 10 ))mb"
fi
# Временные файлы — на локальный диск узла, если кластер его выделяет
export SCRATCH_DIR=${TMPDIR:-/tmp}/abaqus-$SLURM_JOB_ID

echo "узел $(hostname), задача $INP, ядер $CPUS, память ${MEMORY:-по умолчанию}"
scripts/run_job.sh "$INP"
rc=$?
rm -rf "$SCRATCH_DIR"
exit $rc
