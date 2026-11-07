"""Дописывает в модель OpenCourant то, что конвертер inp2rad теряет.

    python3 patch_rad.py model.inp model_0000.rad

1. Разрушение волокон. В задачах серии задано *Damage Initiation, criterion=DUCTILE
   (элемент разрушается при пластической деформации eps_f); inp2rad переносит только
   критерий Johnson-Cook и молча пропускает DUCTILE — без этого волокна не рвутся,
   и образец «тянется». При одной строке данных DUCTILE — постоянный порог eps_f;
   в OpenCourant ему соответствует /FAIL/JOHNSON с D1 = eps_f, D2..D5 = 0.
   Ifail_so = 1: элемент, достигший порога, удаляется — как в Abaqus/Explicit.

2. Идеальная пластичность. Если в *Plastic одна строка (только предел текучести —
   у матрицы-полисульфона), inp2rad пишет кривую текучести из одной точки; решатель
   с такой кривой удаляет элементы матрицы в самом начале расчёта. Добавляем вторую
   точку с тем же напряжением при пластической деформации 1 — это и есть идеальная
   пластичность, как её понимает Abaqus.

model_0000.rad исправляется на месте.
"""
import re
import sys

inp, rad = sys.argv[1], sys.argv[2]

# --- разрушение: материалы с DUCTILE и порог eps_f (первое число первой строки данных)
fail = {}
mat = None
lines = open(inp, encoding="utf-8", errors="replace").read().splitlines()
for i, l in enumerate(lines):
    s = l.strip().lower()
    if s.startswith("*material"):
        m = re.search(r"name\s*=\s*([^,\s]+)", l, re.I)
        mat = m.group(1) if m else None
    elif s.startswith("*damage initiation") and "ductile" in s and mat:
        j = i + 1
        while lines[j].startswith("**"):
            j += 1
        fail[mat] = float(lines[j].split(",")[0])
    elif s.startswith("*") and not s.startswith("**") and not s.startswith((
            "*damage", "*density", "*elastic", "*plastic", "*depvar", "*user", "*expansion")):
        mat = None

rl = open(rad, encoding="utf-8", errors="replace").read().split("\n")

# номера материалов в .rad по именам (строка после /MAT/<закон>/<id> — имя)
ids = {}
for i, l in enumerate(rl):
    m = re.match(r"/MAT/[A-Z0-9_]+/(\d+)\s*$", l)
    if m and i + 1 < len(rl):
        ids[rl[i + 1].strip()] = int(m.group(1))

# --- идеальная пластичность: /FUNCT из одной точки -> две точки
fixed = []
out = []
i = 0
while i < len(rl):
    out.append(rl[i])
    m = re.match(r"/FUNCT/(\d+)\s*$", rl[i])
    if m:
        j = i + 1
        block = []
        while j < len(rl) and not rl[j].startswith(("/", "#---")):
            block.append(rl[j])
            j += 1
        pts = [b for b in block[1:] if b.strip() and not b.startswith("#")]
        out.extend(block)
        if len(pts) == 1:
            x, y = pts[0].split()[:2]
            if float(x) == 0.0:
                out.append("%20s%20s" % ("1", y))
                fixed.append("%s (%s)" % (m.group(1), block[0].split(" rate")[0].strip()))
        i = j
        continue
    i += 1
rl = out

# --- карточки разрушения
real = lambda x: "%20s" % repr(float(x))
sep = "#---1----|----2----|----3----|----4----|----5----|----6----|----7----|----8----|----9----|---10----|"
cards, done = [], []
for name, eps in fail.items():
    if name not in ids:
        continue
    mid = ids[name]
    done.append(f"{name} (MAT {mid}, eps_f={eps})")
    cards += [
        sep, f"# Failure {name}: Abaqus DUCTILE eps_f = {eps} -> /FAIL/JOHNSON (D1 = eps_f), element deletion", sep,
        f"/FAIL/JOHNSON/{mid}",
        "#                 D1                  D2                  D3                  D4                  D5",
        real(eps) + real(0) + real(0) + real(0) + real(0),
        "#              EPS_0  Ifail_sh  Ifail_so             EPSFmin                Dadv               Ixfem",
        real(1.0) + "         1         1                   0                   0                   0",
        "#   FAILIP", "          ",
    ]
if cards:
    # перед разделом PARTS (или перед последним /END)
    k = next((i for i, l in enumerate(rl) if l.startswith("#-  2. PARTS")), None)
    if k is not None and k > 0 and rl[k - 1].startswith("#---"):
        k -= 1
    if k is None:
        k = max(i for i, l in enumerate(rl) if l.strip() == "/END")
    rl[k:k] = cards

open(rad, "w", encoding="utf-8").write("\n".join(rl))
print("разрушение (DUCTILE -> /FAIL/JOHNSON):", ", ".join(done) if done else "нет в модели")
print("идеальная пластичность (кривая из 1 точки -> 2 точки), FUNCT:", ", ".join(fixed) if fixed else "не требуется")
