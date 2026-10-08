# Общие функции для scripts/*.sh. Подключается через "source", сам по себе не запускается.

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Загружаем config.env, но переменные, уже заданные в окружении, имеют приоритет:
# "CPUS=8 scripts/run_job.sh ..." переопределяет значение из файла.
load_config() {
    local cfg="${ABQ_CONFIG:-$PROJECT_DIR/config.env}"
    if [ -f "$cfg" ]; then
        local line key
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in ''|'#'*) continue ;; esac
            key=${line%%=*}
            if [ -z "${!key+x}" ]; then
                eval "export $line"
            fi
        done < "$cfg"
    fi

    : "${RUNTIME:=apptainer}"
    : "${SIF:=$PROJECT_DIR/abaqus-2022.sif}"
    : "${DOCKER_IMAGE:=abaqus:2022}"
    : "${ABAQUS_CMD:=abaqus}"
    : "${APPTAINER_FLAGS:=}"
    : "${INPUT_DIR:=$PROJECT_DIR/inputs}"
    : "${RESULTS_DIR:=$PROJECT_DIR/results}"
    : "${SCRATCH_DIR:=/tmp/abaqus-scratch}"
    : "${CPUS:=20}"
    : "${MP_MODE:=threads}"
    : "${PRECISION:=single}"
    : "${POSTPROCESS:=1}"
    : "${KEEP_RESTART:=0}"
    export RUNTIME SIF DOCKER_IMAGE ABAQUS_CMD APPTAINER_FLAGS INPUT_DIR RESULTS_DIR SCRATCH_DIR \
           CPUS MP_MODE PRECISION POSTPROCESS KEEP_RESTART

    # Относительные пути — от корня проекта, чтобы скрипты работали из любого каталога
    INPUT_DIR=$(abspath "$INPUT_DIR")
    RESULTS_DIR=$(abspath "$RESULTS_DIR")
    case "$SIF" in /*) ;; *) SIF="$PROJECT_DIR/$SIF" ;; esac
}

abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *)  printf '%s\n' "$PROJECT_DIR/${1#./}" ;;
    esac
}

ncpu() {
    nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu
}

log() {
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${LOG_TAG:-abq}" "$*" >&2
}

# abq_exec <рабочий_каталог> <аргументы abaqus...>
# Запускает Abaqus в выбранной среде. Рабочий каталог задачи виден внутри как /work,
# каталог временных файлов — как /scratch, каталог проекта (скрипты постобработки) — как /project.
abq_exec() {
    local workdir=$1; shift
    mkdir -p "$SCRATCH_DIR"
    local lic=()
    if [ -n "${ABAQUSLM_LICENSE_FILE:-}" ]; then
        lic=(--env "ABAQUSLM_LICENSE_FILE=$ABAQUSLM_LICENSE_FILE")
    fi
    case "$RUNTIME" in
        apptainer|singularity)
            # --cleanenv: переменные хоста не попадают в контейнер (воспроизводимость),
            # нужные передаём явно.
            # APPTAINER_FLAGS без кавычек: может содержать несколько флагов
            # shellcheck disable=SC2086
            "$RUNTIME" exec --cleanenv $APPTAINER_FLAGS ${lic[@]+"${lic[@]}"} \
                --bind "$workdir:/work" --bind "$SCRATCH_DIR:/scratch" \
                --bind "$PROJECT_DIR:/project:ro" \
                --pwd /work "$SIF" "$ABAQUS_CMD" "$@"
            ;;
        docker)
            [ ${#lic[@]} -gt 0 ] && lic=(-e "ABAQUSLM_LICENSE_FILE=$ABAQUSLM_LICENSE_FILE")
            # --network host: доступ к серверу лицензий; --init: корректная передача сигналов.
            docker run --rm --init --network host --shm-size=2g \
                --user "$(id -u):$(id -g)" -e HOME=/work ${lic[@]+"${lic[@]}"} \
                -v "$workdir:/work" -v "$SCRATCH_DIR:/scratch" \
                -v "$PROJECT_DIR:/project:ro" \
                -w /work "$DOCKER_IMAGE" "$ABAQUS_CMD" "$@"
            ;;
        native)
            ( cd "$workdir" && "$ABAQUS_CMD" "$@" )
            ;;
        *)
            log "Неизвестный RUNTIME=$RUNTIME (ожидается apptainer|docker|native)"
            return 2
            ;;
    esac
}

# Пути "внутри" среды выполнения для аргументов abaqus (scratch=..., скрипты постобработки)
scratch_path() { [ "$RUNTIME" = native ] && printf '%s\n' "$SCRATCH_DIR" || printf '/scratch\n'; }
project_path() { [ "$RUNTIME" = native ] && printf '%s\n' "$PROJECT_DIR" || printf '/project\n'; }
