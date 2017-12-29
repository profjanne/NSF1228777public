*********************************************************************************
* This set of code is for the research project "Elastic Pathing: Your Speed is
* Enough to Track You". Please refer to the paper for detailed description about
* this project.
*
* The code is from Human-Computer Interaction research lab in Rutgers 
* University New Brunswick.
*
* The code is edited and modified by the following authors:
*
* Xianyi Gao
* Email: xianyi.gao@rutgers.edu
*
* Bernhard Firner
* Email: bfirner@winlab.ruters.edu
*
* Shridatt Sugrim
* Email: ssugrim@winlab.rutgers.edu
*
* Victor Kaiser-Pendergrast
* Email: v.kaiser.pendergrast@gmail.com
*
* Yulong Yang
* Email: yy231@scarletmail.rutgers.edu
* 
* Janne Lindqvist
* Email: janne@winlab.rutgers.edu
*
************************************************************************************

The path identification task is as follows:

Given the speeds of a person's vehicle sampled at a regular interval, the
driver's starting location, and a map, we try to infer which path the driver
took and the eventual destination of the driver.

Our approach is as follows: first analyze the speed data and identify when
turns could have occured along with the maximum angle of those turns.
Next, step through the map keeping track of every path that is logically
consistent with the observed possible turns and actual driving speeds.

To do this we keep track of a current node, a next node, and the progress
of the driver from the current node to the next node. Whenever enough
progress is made to reach the next node (based upon speed values and
the sampling interval, ie 60 mph for 1 second would translate to a
progress of 0.016666 miles) then we consider all possible connecting
nodes as possible next points. We compute the angle of the turn
required to reach each of the next points in degrees and consider
each next node a valid path if its angle is less than the current possible
angle given the vehicle's speed. For instance, if the vehicle is going at
30 mph then we might only accept angles of 45 degrees or less, but a car
going at 15 mph could make turns of 90 degrees.

HOW TO RUN THE PROGRAM:

This program is written in ruby. "elastic_pathing.rb" is the main file.

The program can run by calling:

ruby elastic_pathing.rb <trace file in sq3 type> <map file in sq3 type>

Output is stored in "manual_pathing_{track_name}.txt" where track_name is the name for the trace file. There are some sample trace files in sq3 type showing the formatting. Also, there are some sample map sq3 files. The map is the Open Stree Map with nodes, ways, and other tables in the file. The code for downloading the map is in "get_map.rb".

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

