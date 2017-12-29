There are two python scripts for converting the Seattle traces from txt file format to sq3 format that can be used in our Elastic Pathing program.

The original txt files of Seattle traces can be obtained online through the following link:
http://research.microsoft.com/en-us/um/people/jckrumm/GPSData2009/index.html
The dataset is originally collected by MSR.

HOW TO USE TWO SCRIPTS:

convertTxt.py: This script is used to convert the txt files to sq3 files.
Usage -- Python convertTxt.py file destination_folder_path filename
"file" is the original txt file.
"destination_folder_path" is where you want to store the converted files.
"filename" is the filename for sq3 files. (If there are more than one files generated from the same txt file, the files will be named as "filename_{some number}")

find_closest.py: This script is to insert a first node table for the sq3 files generated using convertTxt.py. Our pathing algorithm needs the information of starting location, so a first node table should be created for each trace. To use this script, there should also be a open street map database downloaded using our get_map.rb script included in this package. The name of the map database needs to be updated within the find_closest.py before using it.
Usage -- python find_closest.py folder_path
"folder_path" is the directory where the sq3 files are stored.

More details about the study appear in our paper
Bibtex format:
@inproceedings{elastic_pathing,
 author = {Gao, Xianyi and Firner, Bernhard and Sugrim, Shridatt and Kaiser-Pendergrast, Victor and Yang, Yulong and Lindqvist, Janne},
 title = {Elastic Pathing: You Speed is Enough to Track You},
 booktitle = {Proceedings of the 2014 ACM International Joint Conference on Pervasive and Ubiquitous Computing},
 series = {UbiComp '14},
 year = {2014},
 url = {http://dx.doi.org/10.1145/2632048.2632077},
 doi = {10.1145/2632048.2632077},
 publisher = {ACM},
}
Our resources are free to use for non-commercial research or educational purposes. You must not attempt to deanonymize the participants from our dataset. If you intend to publish your results based on our code or dataset, we appreciate if you cite the above paper in which we extensively use the code and dataset.

