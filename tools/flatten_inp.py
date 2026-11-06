#!/usr/bin/env python3
"""«Сплющивание» входного файла Abaqus: модель Part/Assembly/Instance -> плоская модель.

    python3 tools/flatten_inp.py Job-24-12-01-1.inp Job-24-12-01-1_flat.inp

Зачем: конвертер inp2rad (Abaqus .inp -> OpenCourant .rad) не понимает модели с
*Part / *Instance, а Abaqus/CAE по умолчанию сохраняет именно так.

Что делает (поддерживается ровно один экземпляр детали без переноса/поворота; сетка
может лежать как внутри *Instance, так и внутри *Part):
  * удаляет строки *Part, *End Part, *Assembly, *End Assembly, *Instance, *End Instance;
  * узлы, заданные на уровне сборки (например, опорная точка RP), перенумеровывает
    после последнего узла детали — иначе номера совпадут (в Abaqus у них разные
    пространства имён: ASSEMBLY.1 и UDComponent-1.1);
  * убирает префикс экземпляра в ссылках (UDComponent-1.ZBack -> ZBack) и параметр
    instance=... у наборов;
  * в наборах узлов уровня сборки номера узлов сборки заменяются на новые.
Если модель сложнее (несколько экземпляров, перенос/поворот) — останавливается с ошибкой.
"""
import re
import sys


def kw(line):
    """Имя ключевого слова в нижнем регистре ('*node output' -> 'node output') или None."""
    s = line.strip()
    if not s.startswith("*") or s.startswith("**"):
        return None
    return s[1:].split(",")[0].strip().lower()


def param(line, name):
    m = re.search(r",\s*" + name + r"\s*=\s*([^,\s]+)", line, re.I)
    return m.group(1) if m else None


def main(src, dst):
    lines = open(src, encoding="latin-1").read().splitlines()

    instances = [l for l in lines if kw(l) == "instance"]
    if len(instances) != 1:
        sys.exit(f"ОШИБКА: поддерживается ровно один *Instance, найдено {len(instances)}")
    inst_name = param(instances[0], "name")
    i_inst = next(i for i, l in enumerate(lines) if kw(l) == "instance")
    nxt = lines[i_inst + 1].strip()
    if not nxt.startswith("*"):
        sys.exit("ОШИБКА: у *Instance задан перенос/поворот — такая модель не поддерживается")

    # 1. Где мы находимся: на уровне детали (сетка внутри *Part — «зависимый» экземпляр,
    #    или внутри *Instance — «независимый»), на уровне сборки или модели
    region = []          # для каждой строки: 'instance' / 'assembly' / 'model'
    state = "model"
    for l in lines:
        k = kw(l)
        if k in ("instance", "part"):
            state = "instance"
        elif k == "end instance":
            region.append("instance"); state = "assembly"; continue
        elif k == "end part":
            region.append("instance"); state = "model"; continue
        elif k == "assembly":
            state = "assembly"
        elif k == "end assembly":
            region.append("assembly"); state = "model"; continue
        region.append(state)

    # 2. Максимальный номер узла детали и узлы уровня сборки
    max_node, asm_nodes, cur = 0, [], None
    for l, r in zip(lines, region):
        k = kw(l)
        if k is not None:
            cur = (k, r)
            continue
        if l.strip().startswith("**") or not l.strip():
            continue
        if cur == ("node", "instance"):
            max_node = max(max_node, int(l.split(",")[0]))
        elif cur == ("node", "assembly"):
            asm_nodes.append(int(l.split(",")[0]))
    remap = {n: max_node + i + 1 for i, n in enumerate(asm_nodes)}

    # 3. Запись
    out, cur, gen = [], None, False
    prefix = re.compile(re.escape(inst_name) + r"\.", re.I)
    dropped = {"part", "end part", "assembly", "end assembly", "instance", "end instance"}
    for l, r in zip(lines, region):
        k = kw(l)
        if k is not None:
            if k in dropped:
                continue
            cur = (k, r, param(l, "instance"))
            gen = bool(re.search(r",\s*generate", l, re.I))
            l = re.sub(r",\s*instance\s*=\s*[^,\s]+", "", l, flags=re.I)
            out.append(prefix.sub("", l))
            continue
        s = l.strip()
        if s.startswith("**") or not s or cur is None:
            out.append(prefix.sub("", l))
            continue
        k, r, inst = cur
        if k == "node" and r == "assembly":
            parts = l.split(",")
            parts[0] = str(remap[int(parts[0])])
            out.append(",".join(parts))
        elif k == "nset" and r == "assembly" and inst is None:
            # набор узлов сборки: номера — узлы сборки (или имена наборов)
            if gen:
                sys.exit("ОШИБКА: *Nset, generate на уровне сборки не поддерживается")
            items = [x.strip() for x in l.split(",") if x.strip()]
            new = [str(remap[int(x)]) if x.isdigit() else prefix.sub("", x) for x in items]
            out.append(", ".join(new))
        else:
            out.append(prefix.sub("", l))

    with open(dst, "w", encoding="latin-1") as f:
        f.write("\n".join(out) + "\n")
    print(f"{src} -> {dst}: экземпляр {inst_name}, узлов детали до {max_node}, "
          f"узлов сборки перенумеровано: {len(remap)} {remap}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
