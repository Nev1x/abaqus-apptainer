#!/usr/bin/env bash
# Этап подготовки: экспорт входных файлов .inp из базы модели Abaqus/CAE (.cae).
#
#   scripts/export_inputs.sh archive/24-12-02.cae                 # все задачи из .cae
#   scripts/export_inputs.sh archive/24-12-02.cae 'Job-.*-1[0-9]$' # по регулярному выражению
#
# Выполняется "abaqus cae noGUI" в том же контейнере (нужна лицензия CAE).
# Результат: INPUT_DIR/<JOB>.inp и INPUT_DIR/jobs.csv (параметры задач из .cae).
set -euo pipefail
source "$(dirname "$0")/common.sh"
load_config
LOG_TAG=export

[ $# -ge 1 ] || { echo "Использование: $0 <модель.cae> [regex_задач]" >&2; exit 2; }
CAE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
PATTERN=${2:-.*}
mkdir -p "$INPUT_DIR"

# CAE открывает .cae на запись (создаёт .lck) — работаем с копией в INPUT_DIR
cp "$CAE" "$INPUT_DIR/_model.cae"
trap 'rm -f "$INPUT_DIR/_model.cae" "$INPUT_DIR/_model.lck"' EXIT

log "экспорт задач из $(basename "$CAE") (фильтр: $PATTERN) в $INPUT_DIR"
abq_exec "$INPUT_DIR" cae noGUI="$(project_path)/abaqus_scripts/export_inputs.py" -- _model.cae "$PATTERN"
rm -f "$INPUT_DIR"/abaqus.rpy* 2>/dev/null || true
log "готово: $(find "$INPUT_DIR" -maxdepth 1 -name '*.inp' | wc -l | tr -d ' ') файлов .inp"
