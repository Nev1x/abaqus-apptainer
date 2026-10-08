from abaqus import *
from caeModules import *
from part import *
from material import *
from section import *
from assembly import *
from step import *
from interaction import *
from load import *
from mesh import *
from optimization import *
from job import *
from sketch import *
from visualization import *
from connectorBehavior import *
from odbAccess import*
from abaqusConstants import *
import numpy as np

historyVariable = ['Spatial displacement: U3 at Node 1 in NSET RPSET',
                   'Reaction force: RF3 at Node 1 in NSET RPSET']
i = 1
while i < 3:
    odb = openOdb('Job-24-12-01-' + str(i) + '.odb')
    results = []
    for j in range(len(historyVariable)):
        f = XYPlots.XYDataFromHistory(odb=odb, outputVariableName=historyVariable[j], steps=('Step-1',), name='H-Output-1'.format(i))
        results.append(f)
    file1 = open('c:/temp/24-12-02/Job' + str(i) + 'URF.txt', 'w')
    for k in range(len(results[0])):
        file1.write(str(results[0][k][0]).replace('.', ',') + '\t' + format(results[0][k][1], 'f').replace('.', ',') + '\n')
    file1.close()
    i = i + 1
