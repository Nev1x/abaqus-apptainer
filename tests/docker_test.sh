#!/usr/bin/env bash
# Запуск tests/run_tests.sh в Linux-контейнере с настоящим Apptainer (работает и на macOS).
#
#   tests/docker_test.sh [каталог_с_inp] [модель.cae]
#   tests/docker_test.sh inputs archive/24-12-02.cae
#
# Что происходит: в контейнере Rocky Linux 8 ставится Apptainer, собирается тестовый образ
# с заглушкой abaqus (tests/fake-abaqus.def), затем тесты выполняются от обычного
# пользователя — так же, как на вузовском сервере без прав root.
set -euo pipefail
cd "$(dirname "$0")/.."
INPUTS=$(cd "${1:-inputs}" && pwd)
CAE=${2:-}
ls "$INPUTS"/*.inp >/dev/null

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
docker pull -q rockylinux:8 >/dev/null
docker save rockylinux:8 -o "$WORK/rockylinux8.tar"

CAE_MOUNT=() CAE_ARG=
if [ -n "$CAE" ]; then
    CAE_MOUNT=(-v "$(cd "$(dirname "$CAE")" && pwd)/$(basename "$CAE"):/data/model.cae:ro")
    CAE_ARG=/data/model.cae
fi

docker run --rm --privileged \
    -v "$(pwd)":/src:ro -v "$INPUTS":/data/inputs:ro -v "$WORK/rockylinux8.tar":/tmp/rockylinux8.tar:ro \
    ${CAE_MOUNT[@]+"${CAE_MOUNT[@]}"} \
    rockylinux:8 bash -euc "
        dnf -y -q install epel-release >/dev/null && dnf -y -q install apptainer python3 procps-ng findutils >/dev/null
        echo \"Apptainer \$(apptainer --version | cut -d' ' -f3), \$(. /etc/os-release && echo \$PRETTY_NAME), \$(uname -m)\"
        useradd -m student
        mkdir /home/student/proj
        tar -C /src --exclude=./inputs --exclude=./results --exclude=./dataset --exclude='./archive/*.cae' \
            --exclude=./config.env -cf - . | tar -C /home/student/proj -xf -
        cd /home/student/proj
        apptainer build -F /home/student/fake-abaqus.sif tests/fake-abaqus.def > /tmp/build.log 2>&1 \
            || { cat /tmp/build.log; exit 1; }
        chown -R student: /home/student
        # Docker Desktop (macOS) не даёт FUSE вложенному контейнеру, поэтому образ
        # распаковывается во временный каталог (--unsquash). На Linux-сервере это не нужно.
        su student -c 'cd ~/proj && APPTAINER_FLAGS=--unsquash tests/run_tests.sh ~/fake-abaqus.sif /data/inputs $CAE_ARG'
    "
