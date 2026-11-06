#!/usr/bin/env bash
# ШАГ 3. Расчёт одной задачи: файл Abaqus .inp -> кривая сила-перемещение.
#
#   opencourant/run_job.sh inputs/Job-24-12-01-1.inp
#   NP=8 opencourant/run_job.sh inputs/Job-24-12-01-1.inp     # 8 ядер (по умолчанию — все)
#
# Результат: results/<JOB>/curve.csv (time,U3,RF3), STATUS, job.meta, журналы этапов.
# Готовая задача (STATUS=DONE) повторно не считается; FORCE=1 — пересчитать.
set -euo pipefail
source "$(dirname "$0")/common.sh"
load_image

[ $# -eq 1 ] || { echo "Использование: $0 <файл.inp>" >&2; exit 2; }
INP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
[ -f "$INP" ] || die "нет файла $1"
JOB=$(basename "$INP" .inp)
LOG_TAG=$JOB
NP=${NP:-$(ncpu)}
ANIM_DT=${ANIM_DT:-0.25}
D="$RESULTS_DIR/$JOB"
mkdir -p "$D"

if [ "${FORCE:-0}" != 1 ] && [ "$(cat "$D/STATUS" 2>/dev/null)" = DONE ]; then
    log "уже рассчитана — пропуск (пересчитать: FORCE=1)"; exit 0
fi
if ! mkdir "$D/.lock" 2>/dev/null; then
    die "задача уже считается другим процессом (если это не так — удалите $D/.lock)"
fi
trap 'rm -rf "$D/.lock"' EXIT
fail() { echo FAILED > "$D/STATUS"; echo "failed_step=$1" >> "$D/job.meta"; die "$2"; }

rm -f "$D"/model* "$D"/*.log "$D/curve.csv"
echo RUNNING > "$D/STATUS"
cat > "$D/job.meta" <<EOF
job=$JOB
input=$INP
input_sha256=$(sha256 "$INP")
solver=OpenCourant $(cat "$IMG_DIR/VERSION") ($ARCH)
image_sha256=$(sha256 "$IMG_DIR/OpenCourant_${ARCH}.sif")
host=$(hostname)
np=$NP
start=$(date '+%Y-%m-%dT%H:%M:%S')
EOF
T0=$(date +%s)
cd "$D"

log "[1/6] убираю обёртку Part/Assembly (tools/flatten_inp.py)"
oc python3 "$PROJECT_DIR/tools/flatten_inp.py" "$INP" model.inp > flatten.log 2>&1 \
    || fail flatten "не удалось «сплющить» модель — см. $D/flatten.log"

log "[2/6] перевожу Abaqus .inp в формат OpenCourant (inp2rad)"
# echo: конвертер в конце ждёт нажатия Enter
echo | oc python3 /opt/OpenCourant/openradioss_gui/inp2rad.py model.inp > convert.log 2>&1 || true
[ -s model_0000.rad ] && [ -s model_0001.rad ] || fail convert "конвертация не удалась — см. $D/convert.log"

log "[3/6] настраиваю вывод: анимация каждые $ANIM_DT с (вместо 0.01)"
sed -i "/^\/ANIM\/DT/{n;s/.*/0  $ANIM_DT/}" model_0001.rad

log "[4/6] starter: проверка модели и разбиение на $NP доменов"
oc starter_sp -i model_0000.rad -np "$NP" -nt 1 > starter.log 2>&1 || true
grep -q "NORMAL TERMINATION\|TERMINATION WITH WARNING" starter.log && grep -qE "^ +0 ERROR\(S\)" starter.log \
    || fail starter "starter нашёл ошибки в модели — см. $D/model_0000.out (ищите 'ERROR ID')"

log "[5/6] engine: расчёт на $NP ядрах (на 16 ядрах ~5 мин; ход: tail -f $D/engine.log)"
oc mpirun --bind-to none -np "$NP" engine_ompi_sp -i model_0001.rad > engine.log 2>&1 || true
grep -q "NORMAL TERMINATION" engine.log || fail engine "расчёт не завершился нормально — см. конец $D/engine.log"
CYCLES=$(grep "TOTAL NUMBER OF CYCLES" engine.log | awk '{print $NF}')

log "[6/6] извлекаю кривую RF3(U3) и чищу временные файлы"
oc "th_to_csv_$ARCH" modelT01 > th.log 2>&1 || fail th "не удалось прочитать историю modelT01 — см. $D/th.log"
oc python3 "$PROJECT_DIR/tools/oc_results.py" curve modelT01.csv curve.csv >> th.log 2>&1 \
    || fail curve "в истории нет перемещения/реакции опорной точки — см. $D/th.log"
oc python3 "$PROJECT_DIR/tools/oc_results.py" analytic model.inp >> job.meta 2>> th.log || true
rm -f ./*.rst ./*.tmp
# промежуточные файлы можно пересоздать из .inp за 30 с — не храним (~130 МБ на задачу)
[ "${KEEP_ALL:-0}" = 1 ] || rm -f model.inp model_0000.rad
# анимацию оставляем только последнюю (для просмотра поля напряжений), остальное — 30 МБ на кадр
if [ "${KEEP_ANIM:-0}" != 1 ]; then
    anim=(modelA[0-9]*)
    [ -e "${anim[0]}" ] && [ ${#anim[@]} -gt 1 ] && rm -f "${anim[@]:0:${#anim[@]}-1}"
fi

{ echo "cycles=$CYCLES"; echo "wall_seconds=$(( $(date +%s) - T0 ))"; echo "end=$(date '+%Y-%m-%dT%H:%M:%S')"; } >> job.meta
echo DONE > STATUS
log "готово за $(( $(date +%s) - T0 )) с: $D/curve.csv"
