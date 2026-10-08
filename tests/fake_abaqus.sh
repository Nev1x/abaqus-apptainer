#!/bin/bash
# Заглушка команды abaqus для проверки инфраструктуры без дистрибутива и лицензии.
# Повторяет то, на что опираются скрипты: аргументы командной строки, файлы
# <job>.log / .sta / .odb / файлы перезапуска, код возврата, "abaqus python".
#
# Управление через переменные окружения (передаются в контейнер через config/env):
#   FAKE_SECONDS   — длительность "расчёта" (по умолчанию 3)
#   FAKE_FAIL      — регулярное выражение: задачи с таким именем завершаются ошибкой
# Журнал одновременности: /scratch/trace (start/end с метками времени).
set -euo pipefail

if [ "${1:-}" = python ]; then
    script=$2; shift 2
    case "$script" in
        *extract_history.py)
            job=$(basename "$1" .odb)
            [ -f "$1" ] || { echo "odb not found: $1" >&2; exit 1; }
            # Синтетическая кривая "нагрузка — перемещение" с разрушением после пика
            awk 'BEGIN { print "time,U3,RF3";
                 for (i = 0; i <= 50; i++) { t = i / 50; u = 5 * t;
                   f = (t < 0.6) ? 2.5e9 * t / 0.6 : 2.5e9 * (1 - (t - 0.6) / 0.3);
                   if (f < 0) f = -1e6; printf "%.4f,%.6g,%.6g\n", t, u, f } }' > "${job}_history.csv"
            echo "${job}_history.csv: 51 points (fake)"
            ;;
        *) echo "fake abaqus python: $script" ;;
    esac
    exit 0
fi

declare -A A=()
for arg in "$@"; do
    case "$arg" in
        *=*) A[${arg%%=*}]=${arg#*=} ;;
        *)   A[$arg]=1 ;;
    esac
done

if [ -n "${A[information]:-}" ]; then
    echo "Abaqus 2022 (FAKE) on $(. /etc/os-release && echo "$PRETTY_NAME") $(uname -m)"
    exit 0
fi

if [ -n "${A[terminate]:-}" ]; then
    echo "fake abaqus terminate job=${A[job]:-}"
    exit 0
fi

if [ -n "${A[cae]:-}" ]; then
    echo "fake abaqus cae noGUI=${A[noGUI]:-} args: $*"
    exit 0
fi

job=${A[job]:?job= is required}
inp=${A[input]:-$job}.inp
inp=${inp%.inp.inp}.inp
[ -f "$inp" ] || { echo "Abaqus Error: input file $inp not found" >&2; exit 1; }
[ -n "${A[interactive]:-}" ] || { echo "fake: ожидается interactive" >&2; exit 1; }
[ -d "${A[scratch]:-/nonexistent}" ] || { echo "fake: scratch-каталог недоступен" >&2; exit 1; }

trace=${A[scratch]}/trace
echo "start $job $(date +%s.%N)" >> "$trace"
echo "Abaqus JOB $job" > "$job.log"
echo "Abaqus 2022 (FAKE) cpus=${A[cpus]:-1} mp_mode=${A[mp_mode]:-} memory=${A[memory]:-} host=$(hostname)" >> "$job.log"
echo "running inside: $(. /etc/os-release && echo "$PRETTY_NAME")"

sleep "${FAKE_SECONDS:-3}"
echo "end $job $(date +%s.%N)" >> "$trace"

if [ -n "${FAKE_FAIL:-}" ] && [[ $job =~ $FAKE_FAIL ]]; then
    echo "***ERROR: fake failure for $job" > "$job.msg"
    echo "Abaqus/Explicit Analysis exited with an error - Please see the  $job.msg file for possible error messages if the file exists." >> "$job.log"
    echo "Abaqus/Analysis exited with errors" >&2
    exit 1
fi

for ext in odb abq pac res sel stt mdl prt; do head -c 1024 /dev/zero > "$job.$ext"; done
printf '  THE ANALYSIS HAS COMPLETED SUCCESSFULLY\n' > "$job.sta"
echo "Abaqus JOB $job COMPLETED" >> "$job.log"
