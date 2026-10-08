#!/usr/bin/env python3
"""Разбор журнала Abaqus/CAE (.jnl) без Abaqus: какие задачи и модели определены,
с какими параметрами запуска и какими модулями упругости материалов.

    python3 tools/inspect_jnl.py archive/24-12-02.jnl                 # сводка по задачам
    python3 tools/inspect_jnl.py archive/24-12-02.jnl --csv jobs.csv  # таблица в CSV
    python3 tools/inspect_jnl.py archive/24-12-02.jnl --check-inp inputs/
        # сверка: модули в .inp совпадают с моделью в .cae (журнале)

Журнал — это Python-код, который CAE записывает при каждом действии пользователя,
поэтому по нему можно восстановить состояние модели (.cae — бинарный и без Abaqus не читается).
"""
import argparse
import csv
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from inp_utils import natural_key, read_elastic  # noqa: E402

TOKEN = re.compile(
    r"mdb\.Model\((?P<model_args>[^)]*)\)"
    r"|mdb\.models\['(?P<m>[^']+)'\]\.materials\['(?P<mat>[^']+)'\]\.Elastic\(\s*table=\(\(\s*(?P<E>[-+\d.eE]+)"
    r"|mdb\.models\.changeKey\(fromName='(?P<from>[^']+)',\s*toName='(?P<to>[^']+)'\)"
    r"|del mdb\.models\['(?P<delm>[^']+)'\]\n"
    r"|mdb\.Job\((?P<job_args>[^)]*)\)"
    r"|mdb\.jobs\['(?P<sj>[^']+)'\]\.setValues\((?P<set_args>[^)]*)\)"
)
KV = re.compile(r"(\w+)=('[^']*'|mdb\.models\['[^']*'\]|[^,]+)")


def kv(text):
    out = {}
    for k, v in KV.findall(text.replace("\n", " ")):
        v = v.strip()
        m = re.match(r"mdb\.models\['([^']*)'\]", v)
        out[k] = m.group(1) if m else v.strip("'")
    return out


def parse(path):
    text = open(path, encoding="latin-1").read()
    models, jobs = {}, {}
    for t in TOKEN.finditer(text):
        if t.group("model_args") is not None:
            a = kv(t.group("model_args"))
            src = a.get("objectToCopy")
            models[a["name"]] = dict(models.get(src, {})) if src else {}
        elif t.group("m"):
            models.setdefault(t.group("m"), {})[t.group("mat")] = float(t.group("E"))
        elif t.group("from"):
            models[t.group("to")] = models.pop(t.group("from"), {})
        elif t.group("delm"):
            models.pop(t.group("delm"), None)
        elif t.group("job_args") is not None:
            a = kv(t.group("job_args"))
            if "name" in a:
                jobs[a["name"]] = a
        elif t.group("sj"):
            jobs.setdefault(t.group("sj"), {}).update(kv(t.group("set_args")))
    return models, jobs


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("jnl")
    p.add_argument("--csv", help="записать таблицу задач с модулями материалов")
    p.add_argument("--check-inp", metavar="DIR", help="сверить модули с файлами DIR/<job>.inp")
    a = p.parse_args()

    models, jobs = parse(a.jnl)
    names = sorted(jobs, key=natural_key)
    print(f"моделей: {len(models)}, задач: {len(names)}")
    params = ("numCpus", "numDomains", "memory", "explicitPrecision", "parallelizationMethodExplicit")
    distinct = {k: sorted({jobs[n].get(k, "?") for n in names}) for k in params}
    for k, v in distinct.items():
        print(f"  {k}: {', '.join(v)}")

    mats = sorted({m for n in names for m in models.get(jobs[n].get("model"), {})}, key=natural_key)
    if a.csv:
        with open(a.csv, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["job", "model", *params, *[f"E_{m}" for m in mats]])
            for n in names:
                j = jobs[n]
                e = models.get(j.get("model"), {})
                w.writerow([n, j.get("model"), *[j.get(k, "") for k in params], *[e.get(m, "") for m in mats]])
        print(f"таблица: {a.csv} ({len(names)} строк, {len(mats)} материалов)")

    if a.check_inp:
        checked = bad = 0
        for n in names:
            inp = os.path.join(a.check_inp, n + ".inp")
            if not os.path.exists(inp):
                continue
            from_inp = read_elastic(inp)
            from_jnl = models.get(jobs[n].get("model"), {})
            diff = [m for m in from_jnl if abs(from_inp.get(m, float("nan")) - from_jnl[m]) > 1e-6 * abs(from_jnl[m])]
            checked += 1
            if diff:
                bad += 1
                print(f"  НЕ СОВПАДАЕТ {n}: {', '.join(diff[:5])}")
            else:
                print(f"  ok {n}: {len(from_jnl)} материалов совпадают")
        print(f"сверено задач: {checked}, расхождений: {bad}")
        sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
