#!/usr/bin/env python3
"""Сборка итогового набора данных из каталога результатов (только стандартная библиотека).

    python3 tools/make_dataset.py                       # results/ -> dataset/
    python3 tools/make_dataset.py --excel-ru            # ';' и десятичная запятая для русского Excel

Для каждой рассчитанной задачи results/<JOB>/:
  dataset/curves/<JOB>.csv  — кривая: U3 * u_scale, RF3 * f_scale (только точки с RF3 > 0)
  dataset/summary.csv       — по строке на задачу: статус, время счёта, максимум силы,
                              модули упругости всех материалов из .inp (E_Carbon1 ... )

Масштабы по умолчанию взяты из исходного скрипта new_import-25-10-11.py
(output[:,0] *= 2.0; output[:,1] *= 8e-10). Модули волокон берутся из .inp, а не из .cae,
поэтому Abaqus/CAE для этого шага не нужен.
"""
import argparse
import csv
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from inp_utils import natural_key, read_elastic  # noqa: E402


def read_meta(path):
    meta = {}
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1)
                meta[k] = v
    return meta


def read_history(path, xvar, yvar):
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    return [(float(r[xvar]), float(r[yvar])) for r in rows]


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--results", default="results")
    p.add_argument("--out", default="dataset")
    p.add_argument("--x", default="U3", help="переменная по оси X (столбец *_history.csv)")
    p.add_argument("--y", default="RF3", help="переменная по оси Y")
    p.add_argument("--u-scale", type=float, default=2.0)
    p.add_argument("--f-scale", type=float, default=8e-10)
    p.add_argument("--excel-ru", action="store_true", help="разделитель ';' и десятичная запятая")
    a = p.parse_args()

    delim = ";" if a.excel_ru else ","

    def num(x):
        s = f"{x:.6g}"
        return s.replace(".", ",") if a.excel_ru else s

    os.makedirs(os.path.join(a.out, "curves"), exist_ok=True)
    jobs = sorted((d for d in os.listdir(a.results) if os.path.isdir(os.path.join(a.results, d))),
                  key=natural_key)
    rows, materials = [], []
    for job in jobs:
        d = os.path.join(a.results, job)
        status = open(os.path.join(d, "STATUS")).read().strip() if os.path.exists(os.path.join(d, "STATUS")) else "-"
        meta = read_meta(os.path.join(d, "job.meta"))
        inp = os.path.join(d, job + ".inp")
        elastic = read_elastic(inp) if os.path.exists(inp) else {}
        for m in elastic:
            if m not in materials:
                materials.append(m)
        row = {"job": job, "status": status, "wall_s": meta.get("wall_seconds", ""),
               "n_points": "", "max_force": "", "disp_at_max_force": "", **{f"E_{m}": v for m, v in elastic.items()}}

        hist = os.path.join(d, job + "_history.csv")
        if status == "DONE" and os.path.exists(hist):
            curve = [(x * a.u_scale, y * a.f_scale) for x, y in read_history(hist, a.x, a.y) if y > 0]
            with open(os.path.join(a.out, "curves", job + ".csv"), "w", newline="") as f:
                w = csv.writer(f, delimiter=delim)
                w.writerow([f"{a.x}*{a.u_scale:g}", f"{a.y}*{a.f_scale:g}"])
                w.writerows([num(x), num(y)] for x, y in curve)
            if curve:
                xm, ym = max(curve, key=lambda c: c[1])
                row.update(n_points=len(curve), max_force=ym, disp_at_max_force=xm)
        rows.append(row)

    materials.sort(key=natural_key)
    cols = ["job", "status", "wall_s", "n_points", "max_force", "disp_at_max_force"] + [f"E_{m}" for m in materials]
    with open(os.path.join(a.out, "summary.csv"), "w", newline="") as f:
        w = csv.writer(f, delimiter=delim)
        w.writerow(cols)
        for r in rows:
            w.writerow([num(r[c]) if isinstance(r.get(c), float) else r.get(c, "") for c in cols])

    done = sum(r["status"] == "DONE" for r in rows)
    print(f"задач: {len(rows)}, рассчитано: {done}, кривых: {sum(bool(r['n_points']) for r in rows)}")
    print(f"сводка: {os.path.join(a.out, 'summary.csv')}")


if __name__ == "__main__":
    main()
