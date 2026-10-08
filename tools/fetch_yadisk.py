#!/usr/bin/env python3
"""Скачивание файлов из публичной папки Яндекс.Диска (только стандартная библиотека Python).

    python3 tools/fetch_yadisk.py --list
    python3 tools/fetch_yadisk.py --pattern '*.inp' --dest inputs
    python3 tools/fetch_yadisk.py --pattern '24-12-02/*' --dest archive

Уже скачанные файлы с совпадающим размером пропускаются, поэтому прерванную загрузку
можно просто запустить заново. Контрольные суммы SHA-256 записываются в <dest>/SHA256SUMS
(проверка: cd <dest> && sha256sum -c SHA256SUMS).
"""
import argparse
import fnmatch
import hashlib
import json
import os
import sys
import time
import urllib.parse
import urllib.request

API = "https://cloud-api.yandex.net/v1/disk/public/resources"
DEFAULT_URL = "https://disk.yandex.ru/d/nR2yRT3GM2aCyg"


def api(path, public_key, **params):
    q = urllib.parse.urlencode(dict(public_key=public_key, path=path, **params))
    with urllib.request.urlopen(f"{API}?{q}", timeout=60) as r:
        return json.load(r)


def walk(public_key, path="/"):
    offset = 0
    while True:
        d = api(path, public_key, limit=500, offset=offset)
        items = d["_embedded"]["items"]
        for it in items:
            if it["type"] == "dir":
                yield from walk(public_key, it["path"])
            else:
                yield it
        if len(items) < 500:
            break
        offset += 500


def download(public_key, item, dest_root):
    rel = item["path"].lstrip("/")
    out = os.path.join(dest_root, rel)
    if os.path.exists(out) and os.path.getsize(out) == item["size"]:
        print(f"  есть   {rel}")
        return out
    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    q = urllib.parse.urlencode(dict(public_key=public_key, path=item["path"]))
    with urllib.request.urlopen(f"{API}/download?{q}", timeout=60) as r:
        href = json.load(r)["href"]
    tmp = out + ".part"
    t0 = time.time()
    for attempt in range(5):
        try:
            with urllib.request.urlopen(href, timeout=120) as r, open(tmp, "wb") as f:
                while True:
                    chunk = r.read(1 << 20)
                    if not chunk:
                        break
                    f.write(chunk)
            break
        except OSError as e:
            print(f"  повтор {rel}: {e}", file=sys.stderr)
            time.sleep(5 * (attempt + 1))
    else:
        raise SystemExit(f"не удалось скачать {rel}")
    if os.path.getsize(tmp) != item["size"]:
        raise SystemExit(f"размер не совпал: {rel}")
    os.replace(tmp, out)
    mb = item["size"] / 1e6
    print(f"  скачан {rel} ({mb:.1f} МБ, {mb / max(time.time() - t0, 1e-3):.1f} МБ/с)")
    return out


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--url", default=DEFAULT_URL, help="публичная ссылка на папку")
    p.add_argument("--pattern", action="append", help="маска пути внутри папки (можно несколько), напр. '*.inp'")
    p.add_argument("--dest", default="inputs", help="куда сохранять")
    p.add_argument("--flat", action="store_true", help="не воссоздавать подкаталоги")
    p.add_argument("--list", action="store_true", help="только показать список файлов")
    a = p.parse_args()

    patterns = a.pattern or ["*"]
    items = [it for it in walk(a.url)
             if any(fnmatch.fnmatch(it["path"].lstrip("/"), pt) for pt in patterns)]
    total = sum(it["size"] for it in items)
    print(f"файлов: {len(items)}, объём: {total / 1e9:.2f} ГБ")
    if a.list:
        for it in items:
            print(f"{it['size']:>14} {it['path']}")
        return
    os.makedirs(a.dest, exist_ok=True)
    sums = []
    for it in items:
        if a.flat:
            it = dict(it, path="/" + os.path.basename(it["path"]))
        out = download(a.url, it, a.dest)
        sums.append(f"{sha256(out)}  {os.path.relpath(out, a.dest)}\n")
    with open(os.path.join(a.dest, "SHA256SUMS"), "w") as f:
        f.writelines(sorted(sums, key=lambda s: s.split("  ", 1)[1]))
    print(f"контрольные суммы: {os.path.join(a.dest, 'SHA256SUMS')}")


if __name__ == "__main__":
    main()
