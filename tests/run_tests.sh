#!/usr/bin/env bash
# Сквозная проверка инфраструктуры с заглушкой Abaqus в настоящем Apptainer.
# Выполняется на Linux от обычного пользователя (без root), из корня копии проекта:
#   tests/run_tests.sh <образ.sif> <каталог_с_inp> [модель.cae]
# Обычно запускается через tests/docker_test.sh (на macOS / любой машине с Docker).
set -uo pipefail

SIF=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
SRC_INPUTS=$2
CAE=${3:-}
cd "$(dirname "$0")/.."
ROOT=$(pwd)

pass=0; fail=0
ok()   { echo "  [OK]   $*"; pass=$((pass + 1)); }
bad()  { echo "  [FAIL] $*"; fail=$((fail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
st()   { cat "results/$1/STATUS" 2>/dev/null; }

# Изолированная конфигурация теста
rm -rf inputs results dataset /tmp/abq-test-scratch
mkdir -p inputs
cp "$SRC_INPUTS"/*.inp inputs/
cat > config.env <<EOF
RUNTIME=apptainer
SIF=$SIF
INPUT_DIR=./inputs
RESULTS_DIR=./results
SCRATCH_DIR=/tmp/abq-test-scratch
CPUS=2
PARALLEL=2
MP_MODE=threads
POSTPROCESS=1
KEEP_RESTART=0
APPTAINER_FLAGS=${APPTAINER_FLAGS:-}
EOF
export APPTAINERENV_FAKE_SECONDS=3
JOBS=$(cd inputs && ls *.inp | sed 's/\.inp$//' | sort -V)
FIRST=$(echo "$JOBS" | head -n1)
LAST=$(echo "$JOBS" | tail -n1)
NJOBS=$(echo "$JOBS" | wc -l)
echo "Пользователь: $(id -un) (uid $(id -u)); задач: $NJOBS; ошибка будет у $LAST"

echo "1. Образ запускается"
out=$(apptainer exec ${APPTAINER_FLAGS:-} "$SIF" abaqus information=release 2>&1)
check "abaqus information=release -> $out" grep -q "Abaqus 2022" <<< "$out"

echo "2. Очередь: $NJOBS задач, по 2 одновременно, одна завершается ошибкой"
APPTAINERENV_FAKE_FAIL="^${LAST}\$" scripts/run_queue.sh > /tmp/q1.log 2>&1
rc=$?
check "очередь вернула код 1 (есть ошибка)" test $rc -eq 1
for j in $JOBS; do
    if [ "$j" = "$LAST" ]; then check "$j: FAILED" test "$(st "$j")" = FAILED
    else check "$j: DONE" test "$(st "$j")" = DONE; fi
done
check "ошибка решателя попала в журнал очереди" grep -q "fake failure" /tmp/q1.log
check "файлы перезапуска удалены, .odb оставлен" \
    bash -c "[ -f results/$FIRST/$FIRST.odb ] && [ ! -e results/$FIRST/$FIRST.abq ] && [ ! -e results/$FIRST/$FIRST.stt ]"
check "постобработка создала ${FIRST}_history.csv" test -s "results/$FIRST/${FIRST}_history.csv"
check "расчёт шёл внутри контейнера Rocky Linux" grep -q "Rocky Linux" "results/$FIRST/run.out"
check "в job.meta есть sha256 входного файла" grep -q "^inp_sha256=[0-9a-f]\{64\}$" "results/$FIRST/job.meta"
check "abaqus получил cpus=2 mp_mode=threads и долю памяти" grep -q "cpus=2 mp_mode=threads memory=45%" "results/$FIRST/$FIRST.log"
maxpar=$(awk '{ ev[NR] = $3 " " ($1 == "start" ? 1 : -1) } END { for (i in ev) print ev[i] }' /tmp/abq-test-scratch/trace \
         | sort -n | awk '{ c += $2; if (c > m) m = c } END { print m }')
check "одновременно выполнялось не больше 2 задач (факт: $maxpar)" test "$maxpar" -le 2 -a "$maxpar" -ge 2

echo "3. Повторный запуск продолжает с места остановки"
starts_before=$(grep -c "^start $FIRST " /tmp/abq-test-scratch/trace)
scripts/run_queue.sh > /tmp/q2.log 2>&1
check "очередь вернула 0" test $? -eq 0
check "готовые задачи пропущены" test "$(grep -c "^start $FIRST " /tmp/abq-test-scratch/trace)" -eq "$starts_before"
check "$LAST пересчитана: DONE" test "$(st "$LAST")" = DONE

echo "4. Прерывание расчёта (SIGTERM, как при scancel или перезагрузке)"
APPTAINERENV_FAKE_SECONDS=60 FORCE=1 scripts/run_job.sh "inputs/$FIRST.inp" > /tmp/q3.log 2>&1 &
pid=$!
sleep 4
check "во время расчёта статус RUNNING" test "$(st "$FIRST")" = RUNNING
APPTAINERENV_FAKE_SECONDS=1 scripts/run_job.sh "inputs/$FIRST.inp" > /tmp/q4.log 2>&1
check "второй запуск той же задачи не начат (блокировка)" grep -q "уже выполняется" /tmp/q4.log
kill -TERM $pid; wait $pid 2>/dev/null
check "после SIGTERM статус INTERRUPTED" test "$(st "$FIRST")" = INTERRUPTED
check "блокировка снята" test ! -e "results/$FIRST/.lock"
check "процессы решателя остановлены" bash -c "! pgrep -f '^sleep 60$' >/dev/null"
APPTAINERENV_FAKE_SECONDS=1 scripts/run_job.sh "inputs/$FIRST.inp" > /tmp/q5.log 2>&1
check "перезапуск прерванной задачи: DONE" test "$(st "$FIRST")" = DONE

echo "5. Устаревшая блокировка (процесс убит kill -9)"
mkdir "results/$FIRST/.lock"; echo "$(hostname):999999" > "results/$FIRST/.lock/owner"
APPTAINERENV_FAKE_SECONDS=1 FORCE=1 scripts/run_job.sh "inputs/$FIRST.inp" > /tmp/q6.log 2>&1
check "устаревшая блокировка снята, задача выполнена" bash -c "grep -q 'устаревшую' /tmp/q6.log && [ \"\$(cat results/$FIRST/STATUS)\" = DONE ]"

echo "6. Сводка и набор данных"
scripts/status.sh > /tmp/status.txt
check "status.sh: все DONE" grep -q "DONE: $NJOBS " /tmp/status.txt
python3 tools/make_dataset.py > /tmp/ds.log
check "summary.csv: $NJOBS строк" test "$(($(wc -l < dataset/summary.csv) - 1))" -eq "$NJOBS"
check "summary.csv: столбцы E_Carbon1..E_Carbon27" bash -c "head -1 dataset/summary.csv | grep -q 'E_Carbon27'"
check "кривые в dataset/curves" test "$(ls dataset/curves | wc -l)" -eq "$NJOBS"
python3 tools/make_dataset.py --excel-ru --out dataset-ru > /dev/null
check "вариант для русского Excel (';' и запятая)" grep -q '^Job.*;DONE;' dataset-ru/summary.csv

if [ -n "$CAE" ]; then
    echo "7. Экспорт .inp из .cae (вызов abaqus cae noGUI)"
    INPUT_DIR=/tmp/abq-export scripts/export_inputs.sh "$CAE" > /tmp/q7.log 2>&1
    check "abaqus cae noGUI вызван с export_inputs.py и копией модели" \
        grep -q "noGUI=/project/abaqus_scripts/export_inputs.py args: .* -- _model.cae" /tmp/q7.log
    check "временная копия .cae удалена" test ! -e /tmp/abq-export/_model.cae
fi

# Сохранить журналы для отчёта/методички (если задан ABQ_TEST_OUT)
if [ -n "${ABQ_TEST_OUT:-}" ]; then
    mkdir -p "$ABQ_TEST_OUT"
    cp /tmp/q*.log /tmp/status.txt /tmp/ds.log "$ABQ_TEST_OUT"/ 2>/dev/null || true
    cp dataset/summary.csv "$ABQ_TEST_OUT"/ 2>/dev/null || true
    cp "results/$FIRST/job.meta" "$ABQ_TEST_OUT"/job.meta 2>/dev/null || true
fi

echo
echo "Итог: пройдено $pass, ошибок $fail"
[ $fail -eq 0 ]
