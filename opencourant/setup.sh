#!/usr/bin/env bash
# ШАГ 1. Установка решателя OpenCourant (делается один раз).
#
#   opencourant/setup.sh
#
# Скачивает официальный образ Apptainer с GitHub (версия зафиксирована ниже),
# проверяет контрольную сумму и пробный запуск. Нужны только apptainer и curl.
set -euo pipefail
source "$(dirname "$0")/common.sh"
LOG_TAG=setup

# Версия решателя зафиксирована: у всех, кто повторяет расчёт, одинаковый решатель.
VERSION=latest-20261011
SHA_linux64=ab63d1601b2de4c1ec663e5265281a1337fd941b30f9d5911a3e88010c5e2c30
SHA_linuxa64=1b4ada3c96fe0d456a891177ed4490d81816180f50fbb6c0a6ba964124cc730a

case "$(uname -m)" in
    x86_64)         ARCH=linux64 ;;
    aarch64|arm64)  ARCH=linuxa64 ;;
    *) die "процессор $(uname -m) не поддерживается (нужен x86_64 или aarch64)" ;;
esac
[ "$(uname -s)" = Linux ] || die "нужен Linux (сейчас $(uname -s)). На macOS/Windows — см. README, раздел «Нет Linux»"

if ! command -v apptainer >/dev/null; then
    cat >&2 <<'EOF'
ОШИБКА: не найдена команда apptainer. Установите её (нужны права администратора):
  Rocky/Alma/RHEL/CentOS:  sudo dnf install -y epel-release && sudo dnf install -y apptainer
  Ubuntu/Debian:           sudo add-apt-repository -y ppa:apptainer/ppa && sudo apt update && sudo apt install -y apptainer
Если прав нет — попросите администратора установить apptainer.
EOF
    exit 1
fi
command -v curl >/dev/null || die "не найдена команда curl (sudo dnf install curl / sudo apt install curl)"
log "Apptainer $(apptainer --version | awk '{print $NF}'), архитектура $ARCH"

mkdir -p "$IMG_DIR"
SIF="$IMG_DIR/OpenCourant_${ARCH}.sif"
URL="https://github.com/OpenCourant/OpenCourant/releases/download/$VERSION/OpenCourant_${ARCH}.sif"
want_var="SHA_$ARCH"; WANT=${!want_var}

if [ -f "$SIF" ] && [ "$(sha256 "$SIF")" = "$WANT" ]; then
    log "образ уже скачан: $SIF"
else
    log "скачиваю образ решателя (~170 МБ): $URL"
    curl -fL --progress-bar --retry 3 -C - -o "$SIF" "$URL" || die "не удалось скачать образ (проверьте интернет / прокси)"
    GOT=$(sha256 "$SIF")
    [ "$GOT" = "$WANT" ] || die "контрольная сумма не совпала: $GOT (ожидалась $WANT). Удалите $SIF и повторите"
    log "контрольная сумма совпала: $GOT"
fi

# Пробный запуск. Если на сервере нет FUSE (бывает в контейнерах и на старых ядрах),
# Apptainer без root не может смонтировать .sif — тогда распаковываем образ в каталог.
IMAGE="$SIF"
if ! apptainer exec "$SIF" true 2>/dev/null; then
    log "образ не монтируется (нет FUSE) — распаковываю в каталог, это нормально (~1 мин)"
    rm -rf "$IMG_DIR/sandbox"
    apptainer build --sandbox "$IMG_DIR/sandbox" "$SIF" >/dev/null 2>&1 || die "не удалось распаковать образ"
    IMAGE="$IMG_DIR/sandbox"
    apptainer exec "$IMAGE" true || die "образ не запускается даже распакованным — см. README, «Неполадки»"
fi
echo "$IMAGE" > "$IMG_DIR/IMAGE"
echo "$ARCH" > "$IMG_DIR/ARCH"
echo "$VERSION" > "$IMG_DIR/VERSION"

# Проверяем, что внутри есть всё нужное
load_image
for exe in starter_sp engine_ompi_sp "th_to_csv_$ARCH" mpirun python3; do
    oc which "$exe" >/dev/null 2>&1 || die "в образе нет программы $exe"
done
oc test -f /opt/OpenCourant/openradioss_gui/inp2rad.py || die "в образе нет конвертера inp2rad.py"
log "готово: OpenCourant $VERSION ($ARCH), образ: $IMAGE"
log "внутри: $(oc mpirun --version 2>/dev/null | head -n1), $(oc python3 --version 2>&1)"
