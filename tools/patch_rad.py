"""Дописывает в модель OpenCourant то, что конвертер inp2rad теряет или переносит не так,
как в Abaqus, и настраивает расчёт после разрыва волокон.

    python3 patch_rad.py model.inp model_0000.rad [EPS_I] [DAMP_ALPHA] [T_AFTER]

    EPS_I       порог начала разрушения волокон, пластическая деформация (по умолчанию 0.0115)
    DAMP_ALPHA  массовое демпфирование после разрыва, 1/с (по умолчанию 50; 0 — без него)
    T_AFTER     время, с которого включаются контакт и демпфирование (по умолчанию 0.25)

1. Разрушение волокон (*Damage Initiation, criterion=DUCTILE + *Damage Evolution,
   type=DISPLACEMENT). inp2rad его пропускает. Переносим как /FAIL/TAB1:
   - начало разупрочнения — при пластической деформации EPS_I. В .inp стоит 0.015, но
     OpenCourant с этим порогом рвёт волокна при U3 ~ 1.33, а Abaqus — при 1.15-1.25;
     значение 0.0115 подобрано по кривой Abaqus (калибровка, см. README);
   - полное разрушение — при EPS_I + u_f / L, где u_f — перемещение разупрочнения из
     *Damage Evolution (0.015), L = 0.85 — характерный размер элемента волокна
     ((объём волокон / число их элементов)^(1/3)); между ними напряжение падает линейно;
   - повреждение накапливается только при растяжении (трёхосность > 0.15): DUCTILE в .inp
     задан одной точкой при трёхосности 0.333 (растяжение). Без этого оборванные волокна
     «звенят», текут на сжатии и разрушаются по всей длине — расчёт разваливается.
   Полностью разрушенный элемент удаляется — как в Abaqus/Explicit.

2. Идеальная пластичность. Если в *Plastic одна строка (у матрицы-полисульфона), inp2rad
   пишет кривую текучести из одной точки, и решатель удаляет матрицу в начале расчёта.
   Добавляем вторую точку с тем же напряжением при пластической деформации 1.

3. Геометрическое удаление элементов. inp2rad вписывает в /PROP/SOLID удаление элементов,
   растянутых по объёму > 100 раз или с соотношением сторон > 100. В Abaqus такого нет
   (удаляются только полностью повреждённые элементы); у нас оно удаляло растянутую
   матрицу в трещине. Отключаем.

4. После разрыва (с T_AFTER):
   - контакт /INTER/TYPE25 по всем граням (в т. ч. внутренним — они открываются при
     удалении элементов): осколки волокон и матрица не проходят друг сквозь друга и
     не выворачивают элементы (в Abaqus это делает DISTORTION CONTROL);
   - слабое массовое демпфирование /DAMP: гасит «звон» оборванных волокон. Добавляет
     к силе после разрыва ~0.02e12 (alpha * масса * скорость), до разрыва не действует.

model_0000.rad исправляется на месте.
"""
import re
import sys

inp, rad = sys.argv[1], sys.argv[2]
EPS_I = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0115
DAMP = float(sys.argv[4]) if len(sys.argv) > 4 else 50.0
T_AFTER = float(sys.argv[5]) if len(sys.argv) > 5 else 0.25
L_EL = 0.85

# --- разрушение: материалы с DUCTILE, их порог и перемещение разупрочнения
fail, uf = {}, {}
mat = None
lines = open(inp, encoding="utf-8", errors="replace").read().splitlines()


def data(i):
    j = i + 1
    while lines[j].startswith("**"):
        j += 1
    return float(lines[j].split(",")[0])


for i, l in enumerate(lines):
    s = l.strip().lower()
    if s.startswith("*material"):
        m = re.search(r"name\s*=\s*([^,\s]+)", l, re.I)
        mat = m.group(1) if m else None
    elif s.startswith("*damage initiation") and "ductile" in s and mat:
        fail[mat] = data(i)
    elif s.startswith("*damage evolution") and "displacement" in s and mat:
        uf[mat] = data(i)
    elif s.startswith("*") and not s.startswith("**") and not s.startswith((
            "*damage", "*density", "*elastic", "*plastic", "*depvar", "*user", "*expansion")):
        mat = None

rl = open(rad, encoding="utf-8", errors="replace").read().split("\n")

# номера материалов в .rad по именам (строка после /MAT/<закон>/<id> — имя); номера деталей
ids = {}
parts = []
for i, l in enumerate(rl):
    m = re.match(r"/MAT/[A-Z0-9_]+/(\d+)\s*$", l)
    if m and i + 1 < len(rl):
        ids[rl[i + 1].strip()] = int(m.group(1))
    m = re.match(r"/PART/(\d+)\s*$", l)
    if m:
        parts.append(int(m.group(1)))

# --- 2. идеальная пластичность: /FUNCT из одной точки -> две точки
# --- 3. геометрическое удаление элементов в /PROP/SOLID -> выключено
fixed, nogeo = [], 0
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
    if rl[i].startswith("#") and "Vdef_min" in rl[i] and "ASP_max" in rl[i] and i + 1 < len(rl):
        v = rl[i + 1].split()
        out.append("%20s" % v[0] + "%20s" % "0.0" * 4)  # dt_min оставляем, критерии удаления = 0
        nogeo += 1
        i += 2
        continue
    i += 1
rl = out

# --- 1, 4. карточки
R = lambda x: "%20s" % repr(float(x))
sep = "#---1----|----2----|----3----|----4----|----5----|----6----|----7----|----8----|----9----|---10----|"
cards, funcs, done = [], [], []
for name, eps_inp in fail.items():
    if name not in ids:
        continue
    mid = ids[name]
    ef = EPS_I + uf.get(name, 0.0) / L_EL
    fid = 90000 + mid
    done.append(f"{name} (MAT {mid}: начало {EPS_I}, разрушение {ef:.4f}; в .inp {eps_inp}, u_f {uf.get(name, 0)})")
    cards += [
        sep, f"# Failure {name}: Abaqus DUCTILE {eps_inp} + evolution u_f={uf.get(name, 0)} -> TAB1, start {EPS_I} (calibrated), full {ef:.4f}", sep,
        f"/FAIL/TAB1/{mid}",
        "# IFAIL_SH  IFAIL_SO                             P_THICKFAIL          P_thinfail",
        "%10d%10d%20s%20s%20s" % (1, 1, "", R(0), R(0)),
        "#              Dcrit                   D                   N                Dadv   fct_IDD",
        R(EPS_I / ef) + R(0) + R(1) + R(0) + "%10d" % 0,
        "#TABLE1_ID             Xscale1             Xscale2 TABLE2_ID             Xscale3             Xscale4",
        "%10d" % fid + R(1) + R(1) + "%10d" % 0 + R(1) + R(1),
        "# fct_IDEL           Fscale_EL              EI_REF          INST_START             FAD_EXP    CH_I_F",
        "%10d" % 0 + R(0) + R(0) + R(0) + R(1) + "%10d" % 0,
        "#  fct_IDT             FscaleT                              Shear_limit             Biax_limit",
        "%10d" % 0 + R(0) + " " * 30 + R(0) + R(0),
    ]
    # предельная деформация от трёхосности: при сжатии (< 0.05) повреждение не копится
    funcs += [f"/FUNCT/{fid}", f"failure strain vs triaxiality, {name}",
              "#                  X                   Y",
              R(-10) + R(10), R(0.05) + R(10), R(0.15) + R(ef), R(10) + R(ef)]

post = []
if parts and fail:
    plist = "".join("%10d" % p for p in parts)
    post += [sep, f"# Contact of fragments after fibre fracture (from t={T_AFTER})", sep,
             "/SURF/PART/ALL/99100", "all faces of all parts, incl. internal (erosion contact)", plist,
             "/INTER/TYPE25/99200", "self contact of fragments after fibre fracture",
             "     99100         0         0         0         0         0                   1         0         0",
             "         0                           0.0                 0.0                 0.0                 0.0",
             "                 0.0                 0.0         0         0                 0.0                 0.0",
             R(0) + R(0) + R(0) + R(T_AFTER) + R(0),
             "         0         0         0                 0.0         0                                0.0",
             "         0         0                 0.0                   0                 0.0                   0"]
    if DAMP > 0:
        post += [sep, f"# Mass damping after fibre fracture (from t={T_AFTER})", sep,
                 "/DAMP/99001", "post-fracture mass damping",
                 "#              ALPHA                BETA   Grnd_ID   Skew_ID              TStart               TStop",
                 R(DAMP) + R(0) + "%10d%10d" % (99001, 0) + R(T_AFTER) + R(1e30),
                 "/GRNOD/PART/99001", "all parts", plist]

if cards or post:
    k = next((i for i, l in enumerate(rl) if l.startswith("#-  2. PARTS")), None)
    if k is not None and k > 0 and rl[k - 1].startswith("#---"):
        k -= 1
    if k is None:
        k = max(i for i, l in enumerate(rl) if l.strip() == "/END")
    rl[k:k] = cards + post
if funcs:
    k = max(i for i, l in enumerate(rl) if l.strip() == "/END")
    rl[k:k] = funcs

open(rad, "w", encoding="utf-8").write("\n".join(rl))
print("разрушение волокон (DUCTILE -> /FAIL/TAB1):", "; ".join(done) if done else "нет в модели")
print("идеальная пластичность (кривая из 1 точки -> 2 точки), FUNCT:", ", ".join(fixed) if fixed else "не требуется")
print("геометрическое удаление элементов выключено в /PROP/SOLID:", nogeo)
print("после t=%g: контакт TYPE25 по деталям %s, демпфирование alpha=%g" % (T_AFTER, parts, DAMP) if post else "контакт/демпфирование: нет")
