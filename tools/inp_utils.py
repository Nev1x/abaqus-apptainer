"""Общие функции для tools/*.py: чтение свойств материалов из .inp."""
import re


def natural_key(s):
    """Job-2 < Job-10 (обычная сортировка дала бы Job-10 < Job-2)."""
    return [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", s)]


# Ключевые слова, после которых описание материала точно закончилось
_END_MATERIAL = ("*part", "*assembly", "*instance", "*step", "*boundary", "*section",
                 "*solid section", "*shell section", "*surface", "*initial", "*amplitude")


def read_elastic(path):
    """{имя_материала: модуль Юнга} из *Material ... *Elastic в файле .inp."""
    result, material, want_data = {}, None, False
    with open(path, encoding="latin-1") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("**"):
                continue
            if s.startswith("*"):
                low = s.lower()
                want_data = False
                if low.startswith("*material"):
                    m = re.search(r"name\s*=\s*([^,\s]+)", s, re.I)
                    material = m.group(1) if m else None
                elif low.startswith("*elastic") and material:
                    want_data = "type=" not in low.replace(" ", "") or "type=iso" in low.replace(" ", "")
                elif low.startswith(_END_MATERIAL):
                    material = None
                continue
            if want_data:
                result[material] = float(s.split(",")[0])
                want_data = False
    return result
