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

# Расчёт (engine) уже завершился, а обработка (шаг 6) нет — не пересчитываем, продолжаем с шага 6
RESUME=0
if [ "${FORCE:-0}" != 1 ] && [ -f "$D/modelT01" ] && grep -q "NORMAL TERMINATION" "$D/engine.log" 2>/dev/null \
        && ! grep -q "RUN KILLED" "$D/engine.log"; then
    RESUME=1
fi

if [ $RESUME = 1 ]; then
log "расчёт уже выполнен — продолжаю с шага 6 (пересчитать заново: FORCE=1)"
echo RUNNING > "$D/STATUS"
sed -i '/^failed_step=/d' "$D/job.meta"
T0=$(date +%s)
cd "$D"
else
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

log "[3/6] дописываю то, что конвертер теряет: разрушение волокон, пластичность матрицы, контакт (tools/patch_rad.py)"
# FIBRE_EPS_I — порог начала разрушения волокон (калибровка по кривой Abaqus, см. README);
# DAMP_ALPHA — демпфирование после разрыва; T_AFTER — с какого времени включаются контакт и демпфирование
FIBRE_EPS_I=${FIBRE_EPS_I:-0.0115}; DAMP_ALPHA=${DAMP_ALPHA:-50}; T_AFTER=${T_AFTER:-0.25}
oc python3 "$PROJECT_DIR/tools/patch_rad.py" model.inp model_0000.rad "$FIBRE_EPS_I" "$DAMP_ALPHA" "$T_AFTER" > patch.log 2>&1 \
    || fail patch "не удалось дополнить модель — см. $D/patch.log"
echo "fibre_eps_i=$FIBRE_EPS_I" >> job.meta; echo "damp_alpha=$DAMP_ALPHA" >> job.meta
# анимация каждые ANIM_DT с вместо 0.01 — в 25 раз меньше места на диске
sed -i "/^\/ANIM\/DT/{n;s/.*/0  $ANIM_DT/}" model_0001.rad
# узловой контроль шага с добавлением массы (его вписывает inp2rad) убираем: после разрыва
# он накачивал массой узлы искажённых элементов (DM/M ~ 1e10) и останавливал расчёт
sed -i "/^\/DT\/NODA\/CST/,+1d" model_0001.rad
T_END=$(awk '/^\/RUN\//{getline; print $1; exit}' model_0001.rad)

log "[4/6] starter: проверка модели и разбиение на $NP доменов"
oc starter_sp -i model_0000.rad -np "$NP" -nt 1 > starter.log 2>&1 || true
grep -q "NORMAL TERMINATION\|TERMINATION WITH WARNING" starter.log && grep -qE "^ +0 ERROR\(S\)" starter.log \
    || fail starter "starter нашёл ошибки в модели — см. $D/model_0000.out (ищите 'ERROR ID')"

log "[5/6] engine: расчёт на $NP ядрах (на 16 ядрах ~10-15 мин; ход: tail -f $D/engine.log)"
oc mpirun --bind-to none -np "$NP" engine_ompi_sp -i model_0001.rad > engine.log 2>&1 || true
grep -q "NORMAL TERMINATION" engine.log || fail engine "расчёт не завершился нормально — см. конец $D/engine.log"
fi
# Решатель может остановиться раньше конца (и всё равно написать NORMAL TERMINATION):
# после разрыва волокон — когда отлетает осколок («NODAL VELOCITY IS TOO HIGH») или
# рушится шаг по времени. Кривая до этого момента верна; если остановка была ещё до
# разрыва (t < T_AFTER) — это ошибка.
T_END=${T_END:-$(awk '/^\/RUN\//{getline; print $1; exit}' model_0001.rad)}
T_LAST=$(grep -o ' T= [0-9.E+-]*' engine.log | tail -n1 | awk '{print $2+0}')
if awk -v a="$T_LAST" -v b="$T_END" 'BEGIN{exit !(a < 0.995*b)}'; then
    WHY=$(grep -h -m1 "NODAL VELOCITY IS TOO HIGH\|TIME STEP LESS OR EQUAL ZERO\|RUN KILLED" model_0001.out engine.log 2>/dev/null | sed 's/^[ *]*//' | head -n1)
    awk -v a="$T_LAST" -v t="${T_AFTER:-0.25}" 'BEGIN{exit !(a < t)}' \
        && fail engine "расчёт остановился до разрыва волокон (t=$T_LAST): ${WHY:-см. $D/engine.log}"
    grep -q '^stopped_at_time=' job.meta || { echo "stopped_at_time=$T_LAST"; echo "stopped_reason=${WHY:-?}"; } >> job.meta
    log "внимание: решатель остановился после разрыва волокон при t=$T_LAST из $T_END ($WHY) — кривая до этого момента"
fi
CYCLES=$(grep "TOTAL NUMBER OF CYCLES" engine.log | awk '{print $NF}')

log "[6/6] извлекаю кривую RF3(U3) и чищу временные файлы"
th_to_csv modelT01 > th.log 2>&1 || fail th "не удалось прочитать историю modelT01 — см. $D/th.log"
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
