#!/usr/bin/env python3
"""Обработка результатов OpenCourant (только стандартная библиотека).

    python3 tools/oc_results.py curve modelT01.csv curve.csv [--node RPset]
        история (th_to_csv) -> curve.csv: time,U3,RF3 (перемещение и реакция по Z узла)

    python3 tools/oc_results.py analytic model.inp
        аналитическая оценка по правилу смесей для образца, растягиваемого вдоль Z:
        K = sum(E_i * V_i) / L^2  (V_i — объём элементов материала i, L — длина по Z)
        печатает строки key=value (дописываются в job.meta)
"""
import csv
import re
import sys


def curve(src, dst, node="RPset"):
    with open(src, newline="") as f:
        r = csv.reader(f)
        head = [" ".join(c.split()) for c in next(r)]
        def col(suffix):
            for i, h in enumerate(head):
                if h.startswith(node) and h.endswith(" " + suffix):
                    return i
            sys.exit("нет столбца '%s ... %s' в %s; есть: %s" % (node, suffix, src,
                     [h for h in head if h.startswith(node)]))
        iu, irf = col("DZ"), col("REACZ")
        rows = [(x[0], x[iu], x[irf]) for x in r]
    with open(dst, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["time", "U3", "RF3"])
        w.writerows(rows)
    print("curve: %d точек -> %s" % (len(rows), dst))


def hex_volume(p):
    """Объём 8-узлового шестигранника: разбиение на 5 тетраэдров."""
    def tet(a, b, c, d):
        ax, ay, az = (b[i] - a[i] for i in range(3))
        bx, by, bz = (c[i] - a[i] for i in range(3))
        cx, cy, cz = (d[i] - a[i] for i in range(3))
        return abs(ax * (by * cz - bz * cy) - ay * (bx * cz - bz * cx) + az * (bx * cy - by * cx)) / 6.0
    return (tet(p[0], p[1], p[3], p[4]) + tet(p[1], p[2], p[3], p[6]) + tet(p[1], p[4], p[5], p[6])
            + tet(p[3], p[4], p[6], p[7]) + tet(p[1], p[3], p[4], p[6]))


def analytic(inp):
    nodes, elems, elsets, sections, mats = {}, {}, {}, [], {}
    mode, cur_set, gen, mat, want_e = None, None, False, None, False
    for line in open(inp, encoding="latin-1"):
        s = line.strip()
        if not s or s.startswith("**"):
            continue
        if s.startswith("*"):
            low = s.lower()
            mode = None
            if low.startswith("*node") and not low.startswith("*node output"):
                mode = "node"
            elif low.startswith("*element") and not low.startswith("*element output"):
                mode = "elem"
            elif low.startswith("*elset"):
                cur_set = re.search(r"elset\s*=\s*([^,\s]+)", s, re.I).group(1)
                gen = "generate" in low
                elsets.setdefault(cur_set, [])
                mode = "elset"
            elif low.startswith("*solid section"):
                es = re.search(r"elset\s*=\s*([^,\s]+)", s, re.I).group(1)
                ma = re.search(r"material\s*=\s*([^,\s]+)", s, re.I).group(1)
                sections.append((es, ma))
            elif low.startswith("*material"):
                mat = re.search(r"name\s*=\s*([^,\s]+)", s, re.I).group(1)
            elif low.startswith("*elastic"):
                want_e = True
                continue
            want_e = False
            continue
        if want_e:
            mats[mat] = float(s.split(",")[0]); want_e = False
        elif mode == "node":
            v = s.split(","); nodes[int(v[0])] = tuple(float(x) for x in v[1:4])
        elif mode == "elem":
            v = [int(x) for x in s.split(",") if x.strip()]; elems[v[0]] = v[1:9]
        elif mode == "elset":
            v = [x.strip() for x in s.split(",") if x.strip()]
            if gen:
                a, b, c = (int(x) for x in v[:3]); elsets[cur_set].extend(range(a, b + 1, c))
            else:
                elsets[cur_set].extend(int(x) for x in v if x.isdigit())
    # длина образца — по узлам элементов (опорная точка RP может стоять вне образца)
    used = {n for conn in elems.values() for n in conn}
    zs = [nodes[n][2] for n in used]
    L = max(zs) - min(zs)
    # последнее назначение секции побеждает (как в Abaqus)
    owner = {}
    for es, ma in sections:
        for e in elsets.get(es, []):
            owner[e] = ma
    vol = {}
    for e, ma in owner.items():
        vol[ma] = vol.get(ma, 0.0) + hex_volume([nodes[n] for n in elems[e]])
    k = sum(mats[m] * v for m, v in vol.items()) / L ** 2
    for m in sorted(vol):
        print("material_%s=E %.6g, area %.4g" % (m, mats[m], vol[m] / L))
    print("length=%.6g" % L)
    print("k_rule_of_mixtures=%.6g" % k)


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "curve":
        node = sys.argv[sys.argv.index("--node") + 1] if "--node" in sys.argv else "RPset"
        curve(sys.argv[2], sys.argv[3], node)
    elif len(sys.argv) == 3 and sys.argv[1] == "analytic":
        analytic(sys.argv[2])
    else:
        sys.exit(__doc__)
