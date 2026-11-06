# Общие функции для opencourant/*.sh (подключается через source).

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMG_DIR="$PROJECT_DIR/opencourant/image"
RESULTS_DIR=${RESULTS_DIR:-$PROJECT_DIR/results}
INPUT_DIR=${INPUT_DIR:-$PROJECT_DIR/inputs}

log()  { printf '%s [%s] %s\n' "$(date '+%H:%M:%S')" "${LOG_TAG:-oc}" "$*" >&2; }
die()  { log "ОШИБКА: $*"; exit 1; }

ncpu() { nproc 2>/dev/null || getconf _NPROCESSORS_ONLN; }

# Путь к образу (или распакованному каталогу) и архитектура — их записывает setup.sh
load_image() {
    [ -f "$IMG_DIR/IMAGE" ] || die "решатель не установлен — сначала выполните: opencourant/setup.sh"
    IMAGE=$(cat "$IMG_DIR/IMAGE")
    ARCH=$(cat "$IMG_DIR/ARCH")
    [ -e "$IMAGE" ] || die "нет образа $IMAGE — повторите opencourant/setup.sh"
}

# Запуск команды внутри образа OpenCourant.
#  --cleanenv: переменные окружения сервера не влияют на расчёт (воспроизводимость);
#  --bind: каталог проекта и результатов видны внутри по тем же путям.
oc() {
    # Apptainer отказывается подключать несуществующий каталог — создаём заранее
    mkdir -p "$RESULTS_DIR" "$INPUT_DIR"
    apptainer exec --cleanenv \
        --env OMP_NUM_THREADS=1 \
        --env PYTHONPATH="$PROJECT_DIR/tools/tk_stub" \
        --bind "$PROJECT_DIR" --bind "$RESULTS_DIR" --bind "$INPUT_DIR" \
        "$IMAGE" "$@"
}

sha256() { (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | cut -d' ' -f1; }
