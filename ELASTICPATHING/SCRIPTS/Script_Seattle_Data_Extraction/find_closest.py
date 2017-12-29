'''
This is a python script to find the correct node on open street map db as the first starting location for every trace
'''

from sqlite3_query import Queryer as Q
import os
import sys
import math

# the scan range for nearest node in degree
NEARBY_RADIUS = 0.005
# the threshold for comparing the trace and the map node, in miles
NEARBY_THRESHOLD = 0.01

COUNTER = 0
FILE_COUNTER = 0
Nodes_on_known_streets = []

def getDist(lat1, long1, node):

    lat2 = node[1]
    long2 = node[2]

    # Convert latitude and longitude to 
    # spherical coordinates in radians.
    degrees_to_radians = math.pi/180.0
        
    # phi = 90 - latitude
    phi1 = (90.0 - lat1)*degrees_to_radians
    phi2 = (90.0 - lat2)*degrees_to_radians
        
    # theta = longitude
    theta1 = long1*degrees_to_radians
    theta2 = long2*degrees_to_radians
        
    # Compute spherical distance from spherical coordinates.
        
    # For two locations in spherical coordinates 
    # (1, theta, phi) and (1, theta, phi)
    # cosine( arc length ) = 
    #    sin phi sin phi' cos(theta-theta') + cos phi cos phi'
    # distance = rho * arc length
    
    cos = (math.sin(phi1)*math.sin(phi2)*math.cos(theta1 - theta2) + 
           math.cos(phi1)*math.cos(phi2))
    arc = math.acos( cos )

    # Remember to multiply arc by the radius of the earth 
    # in your favorite set of units to get length.
    # in miles
    return arc*3959

# given (lat, lon), return the nearest node from the map db
def nearestToNode(lat, lon):
    # setup the area around the node to search in map
    min_lat = abs(lat) - NEARBY_RADIUS
    max_lat = abs(lat) + NEARBY_RADIUS
    min_lon = - ( abs(lon) + NEARBY_RADIUS)
    max_lon = - ( abs(lon) - NEARBY_RADIUS)

    # query the map db and get a list of nodes sorted by distance to the given (lat, lon) within the range
    mapNode = Q('illinois.sq3')
    nearest_20_query = '''SELECT id, latitude, longitude FROM nodes WHERE latitude BETWEEN %f AND %f
         AND longitude BETWEEN %f AND %f;''' % (min_lat, max_lat, min_lon, max_lon)
    nearby = mapNode.selectMany(nearest_20_query)
    # sort the list of nodes by dist
    nearby.sort(key=lambda node: getDist(lat, lon, node))
    mapNode.closeDB()
    # return None if no map node is near the (lat, lon)
    if not nearby:
        return None
    return nearby[0]

# given a trace represented by the db
# return the correct starting node from map db
def findRightNode(dbpath):
    global COUNTER, FILE_COUNTER
    FILE_COUNTER += 1

    # store minimum possible node
    min_dist = 10000000000
    min_node = None
    trace = Q(dbpath)
    mapNode1 = Q('illinois.sq3')
    # grab first 500 nodes of the trace one node per second
    get_trace_query = 'SELECT latitude, longitude, time FROM gpstrace GROUP BY time/1000;'
    get_name_query = 'SELECT name FROM ways WHERE name!="unknown" and nid=%s'
    nodes = trace.selectMany(get_trace_query)
    min_node = nodes[0]
    for index, node in enumerate(nodes):
        true_map_node = nearestToNode(node[0], node[1])
        if not true_map_node:
            continue
        name = mapNode1.selectMany(get_name_query % (true_map_node[0])) 
        #print name
        if name == []:
            continue
        dist = getDist(node[0], node[1], true_map_node) 
        if dist < NEARBY_THRESHOLD:
            print "trace %d pick no.%d %s and map node %s with dist %f at %s" % (FILE_COUNTER, index, name, true_map_node, dist, dbpath)
            trace.closeDB()
            mapNode1.closeDB()
            return node, true_map_node
        # keep a minimum node for backup 
        else:
            if dist < min_dist:
                min_node = node
    default_map_node = nearestToNode(min_node[0], min_node[1])
    if not default_map_node:
        default_map_node = (-1, 99, 99)
    COUNTER += 1
    print "=> %d no.%d and map node %s with dist %f at %s" % (FILE_COUNTER, 0, min_node, getDist(min_node[0], min_node[1], default_map_node), dbpath)
    trace.closeDB()
    mapNode1.closeDB()
    return nodes[0], default_map_node

def populateFirstNodeTable(dbp, n, true_node):
    db = Q(dbp)
    create = "CREATE TABLE IF NOT EXISTS 'firstnode' ('time' NUMBER, 'node id' NUMBER);"
    delete = "delete from firstnode;"
    insert = "insert or replace into 'firstnode' (time, 'node id') values (%s, %s);" % (n[2], true_node[0])
    db.execute(create)
    db.execute(delete)
    db.execute(insert)
    db.closeDB()

# check if the given table already has the first node table
# return True if so, Flase otherwise
def hasFirstNode(dbp):
    db = Q(dbp)
    firstnode = "SELECT * FROM sqlite_master WHERE name ='firstnode';";
    fnode = db.selectOne(firstnode)
    if fnode:
        return True
    else:
        return False

# walk through all db files
# find first node for db who does not have a firstnode table yet
def main(sqpath):
    for dirname, dirnames, filenames in os.walk(sqpath):
        # get path to all filenames.
        for filename in filenames:
            if filename.endswith('.sq3'):
                dbpath = os.path.join(dirname, filename)
                if not hasFirstNode(dbpath):
                    print "find first node for", dbpath
                    node, true_map_node = findRightNode(dbpath)
                    populateFirstNodeTable(dbpath, node, true_map_node)
                '''
                print "find first node for", dbpath
                node, true_map_node = findRightNode(dbpath)
                populateFirstNodeTable(dbpath, node, true_map_node)
                '''

if __name__ == '__main__':
    #getAllNodesOnStreets()
    if len(sys.argv) != 2:
        print "Usage: python find_closest.py folder_path"
    main(sys.argv[1])
    print 'bad nodes percentage: %d/%d' % (COUNTER, FILE_COUNTER)
