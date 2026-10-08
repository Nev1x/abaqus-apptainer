# -*- coding: utf-8 -*-
"""Экспорт .inp для задач из базы .cae. Выполняется внутри Abaqus/CAE (Python 2.7):

    abaqus cae noGUI=export_inputs.py -- model.cae [regex]

Записывает <Job>.inp в текущий каталог и jobs.csv с параметрами задач,
заданными в CAE (число ядер, доменов, точность) — для сверки с config.env.
"""
import os
import re
import sys

from abaqus import openMdb
from abaqusConstants import OFF

args = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
if not args:
    raise SystemExit('usage: abaqus cae noGUI=export_inputs.py -- model.cae [regex]')
cae = args[0]
pattern = re.compile(args[1] if len(args) > 1 else '.*')

openMdb(pathName=cae)
from abaqus import mdb  # после openMdb объект mdb заменяется


def natural_key(s):
    return [int(t) if t.isdigit() else t for t in re.split(r'(\d+)', s)]


names = [n for n in sorted(mdb.jobs.keys(), key=natural_key) if pattern.search(n)]
with open('jobs.csv', 'w') as f:
    f.write('job,model,numCpus,numDomains,explicitPrecision\n')
    for name in names:
        job = mdb.jobs[name]
        print('writeInput: %s (model %s)' % (name, job.model))
        job.writeInput(consistencyChecking=OFF)
        f.write('%s,%s,%s,%s,%s\n' % (name, job.model,
                                       getattr(job, 'numCpus', ''),
                                       getattr(job, 'numDomains', ''),
                                       getattr(job, 'explicitPrecision', '')))
print('exported %d jobs to %s' % (len(names), os.getcwd()))
