#!/usr/bin/env python3
"""Итоговый отчёт по рассчитанным задачам (только стандартная библиотека Python).

    python3 opencourant/report.py results report

Создаёт в каталоге report/:
  summary.csv     — по строке на задачу: модуль волокна, жёсткость (расчёт и правило
                    смесей), силы при U3 = 1, 2, 5, время счёта
  curves.svg      — кривые RF3(U3) всех задач (цвет — модуль волокна)
  stiffness.svg   — начальная жёсткость: расчёт против правила смесей
Графики открываются в любом браузере.
"""
import csv
import os
import re
import sys


def natural_key(s):
    return [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", s)]


def read_meta(path):
    meta = {}
    if os.path.exists(path):
        for line in open(path, encoding="utf-8"):
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1)
                meta[k] = v
    return meta


def slope(pts):
    n = len(pts)
    mx = sum(p[0] for p in pts) / n
    my = sum(p[1] for p in pts) / n
    return sum((x - mx) * (y - my) for x, y in pts) / sum((x - mx) ** 2 for x, _ in pts)


def at(curve, u):
    return min(curve, key=lambda p: abs(p[0] - u))[1]


# ---------- SVG ----------
W, H, ML, MR, MT, MB = 760, 440, 80, 30, 50, 60
INK, INK2, GRID = "#0b0b0b", "#52514e", "#dcdbd5"


def ramp(t):
    """Последовательная шкала одного тона: светло-синий -> тёмно-синий."""
    a, b = (0xa9, 0xc9, 0xf0), (0x0b, 0x3a, 0x73)
    return "#%02x%02x%02x" % tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def nice_ticks(lo, hi, n=5):
    step = (hi - lo) / n
    mag = 10 ** int(("%e" % step).split("e")[1])
    for m in (1, 2, 2.5, 5, 10):
        if m * mag >= step:
            step = m * mag
            break
    t = (lo // step) * step
    out = []
    while t <= hi + 1e-9 * step:
        if t >= lo - 1e-9 * step:
            out.append(round(t, 10))
        t += step
    return out


def svg_chart(path, title, xlabel, ylabel, series, xr, yr, notes=()):
    x0, x1 = xr
    y0, y1 = yr
    sx = lambda x: ML + (x - x0) / (x1 - x0) * (W - ML - MR)
    sy = lambda y: H - MB - (y - y0) / (y1 - y0) * (H - MT - MB)
    o = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" font-family="Arial" font-size="12">' % (W, H),
         '<rect width="100%%" height="100%%" fill="#fcfcfb"/>',
         '<text x="%d" y="28" font-size="15" fill="%s">%s</text>' % (ML, INK, title)]
    for t in nice_ticks(x0, x1):
        o.append('<line x1="%.1f" y1="%d" x2="%.1f" y2="%d" stroke="%s"/>' % (sx(t), MT, sx(t), H - MB, GRID))
        o.append('<text x="%.1f" y="%d" text-anchor="middle" fill="%s">%g</text>' % (sx(t), H - MB + 18, INK2, t))
    for t in nice_ticks(y0, y1):
        o.append('<line x1="%d" y1="%.1f" x2="%d" y2="%.1f" stroke="%s"/>' % (ML, sy(t), W - MR, sy(t), GRID))
        o.append('<text x="%d" y="%.1f" text-anchor="end" fill="%s">%g</text>' % (ML - 8, sy(t) + 4, INK2, t))
    o.append('<text x="%d" y="%d" text-anchor="middle" fill="%s">%s</text>' % ((ML + W - MR) / 2, H - 18, INK2, xlabel))
    o.append('<text transform="translate(20,%d) rotate(-90)" text-anchor="middle" fill="%s">%s</text>'
             % ((MT + H - MB) / 2, INK2, ylabel))
    for s in series:
        if s["kind"] == "line":
            pts = " ".join("%.1f,%.1f" % (sx(x), sy(y)) for x, y in s["pts"])
            dash = ' stroke-dasharray="6 4"' if s.get("dash") else ""
            o.append('<polyline points="%s" fill="none" stroke="%s" stroke-width="%s"%s/>'
                     % (pts, s["color"], s.get("width", 1.5), dash))
        else:
            for x, y in s["pts"]:
                o.append('<circle cx="%.1f" cy="%.1f" r="4.5" fill="%s" stroke="#fcfcfb" stroke-width="1.5"/>'
                         % (sx(x), sy(y), s["color"]))
    for i, n in enumerate(notes):
        o.append('<text x="%d" y="%d" fill="%s">%s</text>' % (ML + 12, MT + 18 + 16 * i, INK2, n))
    o.append("</svg>")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(o))


def main(results, out):
    os.makedirs(out, exist_ok=True)
    rows = []
    for job in sorted(os.listdir(results), key=natural_key):
        d = os.path.join(results, job)
        if not os.path.isdir(d):
            continue
        status = open(os.path.join(d, "STATUS")).read().strip() if os.path.exists(os.path.join(d, "STATUS")) else "-"
        meta = read_meta(os.path.join(d, "job.meta"))
        mats = {k[len("material_"):]: v for k, v in meta.items() if k.startswith("material_")}
        e_by = {m: float(re.search(r"E ([0-9.e+-]+)", v).group(1)) for m, v in mats.items()}
        fibre = max(e_by, key=e_by.get) if e_by else ""
        row = {"job": job, "status": status, "fibre_material": fibre, "E_fibre_GPa": e_by.get(fibre, 0) / 1e9,
               "k_rule_of_mixtures": float(meta.get("k_rule_of_mixtures", "nan")),
               "wall_seconds": meta.get("wall_seconds", ""), "cycles": meta.get("cycles", ""), "curve": []}
        cpath = os.path.join(d, "curve.csv")
        if status == "DONE" and os.path.exists(cpath):
            c = [(float(r["U3"]), float(r["RF3"])) for r in csv.DictReader(open(cpath))]
            row["curve"] = c
            umax = max(u for u, _ in c)
            row["k_sim"] = slope([p for p in c if 0.04 * umax < p[0] < 0.16 * umax])
            row["k_diff_%"] = (row["k_sim"] / row["k_rule_of_mixtures"] - 1) * 100
            for u in (1, 2, 5):
                row["F_at_U%d" % u] = at(c, u)
            row["F_max"] = max(f for _, f in c)
        rows.append(row)

    cols = ["job", "status", "fibre_material", "E_fibre_GPa", "k_sim", "k_rule_of_mixtures", "k_diff_%",
            "F_at_U1", "F_at_U2", "F_at_U5", "F_max", "cycles", "wall_seconds"]
    with open(os.path.join(out, "summary.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(cols)
        for r in rows:
            w.writerow([("%.6g" % r[c]) if isinstance(r.get(c), float) else r.get(c, "") for c in cols])

    done = [r for r in rows if r["curve"]]
    print("задач: %d, рассчитано: %d" % (len(rows), len(done)))
    if not done:
        return
    emin = min(r["E_fibre_GPa"] for r in done)
    emax = max(r["E_fibre_GPa"] for r in done)
    span = (emax - emin) or 1
    ser = [{"kind": "line", "color": ramp((r["E_fibre_GPa"] - emin) / span), "width": 1.2,
            "pts": [(u, f / 1e12) for u, f in r["curve"][::20]]} for r in sorted(done, key=lambda r: r["E_fibre_GPa"])]
    fmax = max(r["F_max"] for r in done) / 1e12
    svg_chart(os.path.join(out, "curves.svg"),
              "Сила RF3 от перемещения U3, %d задач (цвет — модуль волокна)" % len(done),
              "перемещение опорной точки U3", "сила RF3, ×10¹²", ser, (0, 5), (0, fmax * 1.1),
              notes=["светлее — %.0f ГПа, темнее — %.0f ГПа" % (emin, emax)])
    pts = [(r["E_fibre_GPa"], r["k_sim"] / 1e12) for r in done]
    rm = sorted((r["E_fibre_GPa"], r["k_rule_of_mixtures"] / 1e12) for r in done)
    ys = [p[1] for p in pts] + [p[1] for p in rm]
    svg_chart(os.path.join(out, "stiffness.svg"),
              "Начальная жёсткость: расчёт OpenCourant и правило смесей",
              "модуль Юнга волокна, ГПа", "жёсткость K, ×10¹²",
              [{"kind": "line", "color": INK2, "pts": [rm[0], rm[-1]], "dash": True},
               {"kind": "dots", "color": "#2a78d6", "pts": pts}],
              (emin - 2, emax + 2), (min(ys) * 0.98, max(ys) * 1.02),
              notes=["точки — расчёт, пунктир — правило смесей",
                     "среднее расхождение %.2f %%" % (sum(r["k_diff_%"] for r in done) / len(done))])
    print("отчёт: %s/summary.csv, curves.svg, stiffness.svg" % out)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
