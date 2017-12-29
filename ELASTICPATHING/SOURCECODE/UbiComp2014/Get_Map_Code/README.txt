get_map.rb is used to download the required Open Street Map. The boundaries of latitude and longitudes should be provided. Also, the type of output file should also be specified while running the get_map program.

Usage: get_map [OPTIONS]

Given 2 pairs of Lat/Lon, it will chop the square map up into chunks of fixed width. get_map will the download each chunk separately and reassemble the chunks into one large collection of Nodes and Ways. Possible output types are OSM(XML), Database(Sqlite), Text, or Marshall file.

OPTIONS:

'--debug': 'Enable Debug messages (default: false)'

'--minlat MINLAT': '(Default = 40.3718000) Minimum Latitude'

'--minlon MINLON': '(Default = -74.5975000) Minimum Longitude'

'--maxlat MAXLAT': '(Default = 40.4695000) Maximum Latitude'

'--maxlon MAXLON': '(Default = -74.4465000) Maximum Latitude'

'--osmfile FILE':  'PATH to output OSM file (in xml), if not specified, this will  not be output'

'--dbfile FILE': 'PATH to output sqlite3 db, if not specified will  not be output'

'--marfile FILE': 'PATH to output binary store, if not specified will  not be output'

'--txtfile FILE': 'PATH to output text file of node ids for debugging, if not specified will  not be output'

'--threads NUMBER': 'Number of threads, default 2'

'--chunk NUMBER': 'Size of chunks default = 5'

'--help': 'Display this screen'

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

