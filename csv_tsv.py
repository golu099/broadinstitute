import sys 
import os 
import re 
import csv 

#Takes blast tabular resuls and converts it into an excel sheet. 
#argument 1= ''.csv 
#argument 2 = ''.tsv
with open(sys.argv[1], "r") as csv_file, open (sys.argv[2], "w") as tsv_file:
    csv_reader = csv.reader(textfile, delimiter=',')
    lines = csv_file.readlines()[0:]
    empty_list = []
    ##If you want you can add header using append fxn here 
    for i in lines: 
        if '.' in i: 
            empty_list.append(i) 
    print("Performing conversion for " + str(sys.argv[1]) + '\n')
    wr = csv.writer(tsv_file, delimiter = '\t')
    #delimeiter easier for excel file by replace tsv (tab identifier) to "|" and separating these. 
    wr.writerows([elem.replace(',','|').split('|') for elem in empty_list])
csv_file.close()
tsv_file.close()
##see if anything changes part 3
##when you change repo on VS make ue you dont have unsaved changes or else it goes crazy 