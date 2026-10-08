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
import locale

JobName = "Job-24-12-01-"
NumModels = 40
Fibers = 27

def extract_history_output(path, file_name, variable1, variable2, j):
	o1 = session.openOdb('{}{}.odb'.format(path, file_name))
	session.viewports['Viewport: 1'].setValues(displayedObject=o1)
	session.linkedViewportCommands.setValues(_highlightLinkedViewports=False)
	odb = session.odbs['{}{}.odb'.format(path, file_name)]
	xy1 = xyPlot.XYDataFromHistory(odb=odb, outputVariableName=variable1, steps=('Step-1', ), suppressQuery=True, __linkedVpName__='Viewport: 1')
	xy2 = xyPlot.XYDataFromHistory(odb=odb, outputVariableName=variable2, steps=('Step-1', ), suppressQuery=True, __linkedVpName__='Viewport: 1')
	data1=np.array(xy1)
	data2=np.array(xy2)
	output = np.concatenate((data1, data2), axis=1)
	output = np.delete(output, 2, 1)
	output = np.delete(output, 0, 1)
	output[:, 0] *= 2.0
	output = output[(output[:, 1] > 0)]
	output[:, 1] *= 8e-10
	#np.savetxt(file_name + ".output", output)
	try:
    		locale.setlocale(locale.LC_NUMERIC, 'ru_RU.UTF-8')
	except locale.Error:
   		locale.setlocale(locale.LC_NUMERIC, 'Russian_Russia.1251')
	np.savetxt(str(j) + ".output" + ".csv", output, delimiter=', ', fmt='%f')


node_number = 1
history_output2='Reaction force: RF3 PI: rootAssembly Node {} in NSET RPSET'.format(node_number)
history_output1='Spatial displacement: U3 PI: rootAssembly Node {} in NSET RPSET'.format(node_number)


j = 1
young =0
while j < NumModels+1:
	extract_history_output("c:/temp/", JobName + str(j), history_output1, history_output2, j)
	i = 0
	res = np.ones(Fibers)
	while i < Fibers:
		res[i] = mdb.models['Model-'+str(j)].materials['Carbon'+ str(i+1)].elastic.table[0][0]
		i = i + 1
 	np.savetxt(str(j) + ".elastic" + ".csv", res, delimiter=', ', fmt='%f')
   	j = j + 1
