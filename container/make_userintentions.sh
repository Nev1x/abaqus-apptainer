#!/usr/bin/env bash
# Однократная "пробная" интерактивная установка Abaqus 2022 во временном контейнере
# Rocky Linux 8 — чтобы получить файл ответов UserIntentions_CODE.xml для тихой установки.
#
# Инсталлятор задаёт вопросы (каталоги, состав продуктов, сервер лицензий). Ответы
# сохраняются в XML, который затем используется при сборке образа (abaqus-2022.def / Dockerfile).
# Так образ собирается без участия человека и одинаково на любой машине.
#
# Использование:  container/make_userintentions.sh [каталог_media]   (по умолчанию ./media)
# Требуется Docker. Результат: media/UserIntentions_CODE.xml
set -euo pipefail

MEDIA=$(cd "${1:-media}" && pwd)
ls "$MEDIA"/*.AM_SIM_Abaqus_Extend.AllOS.*.tar >/dev/null

cat <<'MSG'
Сейчас запустится текстовый инсталлятор (StartTUI). Рекомендуемые ответы:
  * каталог установки по умолчанию: /usr/SIMULIA/EstProducts/2022
  * каталог команд по умолчанию:    /var/DassaultSystemes/SIMULIA/Commands
  * продукты: Abaqus/Standard, Abaqus/Explicit (CAE и документацию можно не ставить)
  * лицензия: SIMULIA FLEXnet, сервер вида 27000@license.example.org
MSG

docker run --rm -it -v "$MEDIA":/mnt/media rockylinux:8 bash -euc '
    dnf -y -q install which ksh perl tar gzip hostname procps-ng redhat-lsb-core libstdc++ zlib glibc-langpack-en
    mkdir -p /tmp/media
    for t in /mnt/media/*.AM_SIM_Abaqus_Extend.AllOS.*.tar; do tar xf "$t" -C /tmp/media/; done
    for f in $(find /tmp/media -name CheckPrereq.sh -path "*Linux*"); do
        chmod a+w "$f"; sed -i "/DSY_OS_Release=/a DSY_OS_Release=\"centos\"" "$f"; chmod a-w "$f"
    done
    TUI=$(find /tmp/media -path "*SIMULIA_EstablishedProducts/Linux64/1/StartTUI.sh" | head -n1)
    "$TUI"
    XML=$(find /usr/SIMULIA /var/DassaultSystemes -name "UserIntentions_CODE.xml" 2>/dev/null | head -n1)
    test -n "$XML" || { echo "UserIntentions_CODE.xml не найден" >&2; exit 1; }
    cp "$XML" /mnt/media/UserIntentions_CODE.xml
    echo "Сохранено: media/UserIntentions_CODE.xml"
'
