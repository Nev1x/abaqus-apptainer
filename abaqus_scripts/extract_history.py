# -*- coding: utf-8 -*-
"""Извлечение истории (history output) из .odb в CSV без Abaqus/CAE.
Выполняется интерпретатором Abaqus (Python 2.7 в Abaqus 2022, модуль odbAccess):

    abaqus python extract_history.py Job.odb [--step Step-1] [--vars U3,RF3] [--region "Node ASSEMBLY.1"]

Результат: <Job>_history.csv со столбцами time,<var1>,<var2>,...

Заменяет XYDataFromHistory из исходных скриптов (from_abaqus_import/new_import), которые
работали только в графическом CAE на Windows. По умолчанию ищется область истории,
где есть все запрошенные переменные (в задачах 24-12-01 это опорная точка RPset:
"Node ASSEMBLY.1" с U3 и RF3).
"""
from __future__ import print_function

import argparse
import os
import sys

from odbAccess import openOdb

p = argparse.ArgumentParser()
p.add_argument('odb')
p.add_argument('--step', default=None, help='имя шага (по умолчанию последний)')
p.add_argument('--vars', default='U3,RF3')
p.add_argument('--region', default=None, help='имя области истории (по умолчанию — найти)')
a = p.parse_args()
variables = [v.strip() for v in a.vars.split(',') if v.strip()]

odb = openOdb(a.odb, readOnly=True)
step_name = a.step or list(odb.steps.keys())[-1]
step = odb.steps[step_name]

if a.region:
    region = step.historyRegions[a.region]
else:
    candidates = [r for r in step.historyRegions.values()
                  if all(v in r.historyOutputs.keys() for v in variables)]
    if not candidates:
        print('Нет области истории с переменными %s. Доступно:' % variables, file=sys.stderr)
        for r in step.historyRegions.values():
            print('  %s: %s' % (r.name, list(r.historyOutputs.keys())), file=sys.stderr)
        sys.exit(1)
    region = candidates[0]
    if len(candidates) > 1:
        print('Несколько подходящих областей, взята первая: %s' % region.name, file=sys.stderr)

series = [region.historyOutputs[v].data for v in variables]
n = min(len(s) for s in series)
out = os.path.splitext(os.path.basename(a.odb))[0] + '_history.csv'
with open(out, 'w') as f:
    f.write('time,' + ','.join(variables) + '\n')
    for i in range(n):
        f.write('%.9g,' % series[0][i][0] + ','.join('%.9g' % s[i][1] for s in series) + '\n')
odb.close()
print('%s: %d точек, область "%s", шаг %s' % (out, n, region.name, step_name))
