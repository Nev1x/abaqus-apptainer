# syntax=docker/dockerfile:1
# Docker-вариант того же образа, что и container/abaqus-2022.def (для хостов без Apptainer).
#
# Сборка (из корня проекта, нужен BuildKit — включён по умолчанию в Docker >= 23):
#   docker build -f container/Dockerfile -t abaqus:2022 .
#
# Архивы дистрибутива подключаются через --mount=type=bind и не попадают в слои образа.

FROM rockylinux:8

RUN dnf -y install which ksh perl tar gzip hostname procps-ng redhat-lsb-core \
        libstdc++ zlib glibc-langpack-en \
        mesa-libGL mesa-libGLU libXext libXrender libXtst libXi libXmu libXft libXpm libjpeg-turbo \
    && dnf clean all

RUN --mount=type=bind,source=media,target=/mnt/media,readonly \
    set -e; \
    mkdir -p /tmp/media; \
    for t in /mnt/media/*.AM_SIM_Abaqus_Extend.AllOS.*.tar; do tar xf "$t" -C /tmp/media/; done; \
    for f in $(find /tmp/media -name CheckPrereq.sh -path '*Linux*'); do \
        chmod a+w "$f"; sed -i '/DSY_OS_Release=/a DSY_OS_Release="centos"' "$f"; chmod a-w "$f"; \
    done; \
    TUI=$(find /tmp/media -path '*SIMULIA_EstablishedProducts/Linux64/1/StartTUI.sh' | head -n1); \
    test -n "$TUI"; \
    "$TUI" --silent /mnt/media/UserIntentions_CODE.xml; \
    test -x /var/DassaultSystemes/SIMULIA/Commands/abaqus; \
    rm -rf /tmp/media; \
    dnf -y remove perl || true

ENV PATH=/var/DassaultSystemes/SIMULIA/Commands:$PATH \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

WORKDIR /work
CMD ["abaqus", "information=release"]
