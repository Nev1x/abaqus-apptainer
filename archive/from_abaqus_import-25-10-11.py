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

JobName = "Job-24-12-01-"
NumModels = 40


def extract_history_output(path, file_name, variable1, variable2):
	o1 = session.openOdb('{}{}.odb'.format(path, file_name))
	session.viewports['Viewport: 1'].setValues(displayedObject=o1)
	session.linkedViewportCommands.setValues(_highlightLinkedViewports=False)
	odb = session.odbs['{}{}.odb'.format(path, file_name)]
	xy1 = xyPlot.XYDataFromHistory(odb=odb, outputVariableName=variable1, steps=('Step-1', ), suppressQuery=True, __linkedVpName__='Viewport: 1')
	xy2 = xyPlot.XYDataFromHistory(odb=odb, outputVariableName=variable2, steps=('Step-1', ), suppressQuery=True, __linkedVpName__='Viewport: 1')
	data1=np.array(xy1)
	data2=np.array(xy2)
	print("\n data1") 
	print(data1) 
	print("\n data2") 
	print(data1) 
	output = np.concatenate((data1, data2), axis=1)
	output = np.delete(output, 2, 1)
	output = np.delete(output, 1, 1)
	np.savetxt(file_name + ".output", output)

node_number = 1
history_output2='Reaction force: RF3 PI: rootAssembly Node {} in NSET RPSET'.format(node_number)

history_output1='Spatial displacement: U3 PI: rootAssembly Node {} in NSET RPSET'.format(node_number)


j = 1
while j < NumModels+1:
	extract_history_output("c:/temp/", JobName + str(j), history_output1, history_output2)
    	j = j + 1
