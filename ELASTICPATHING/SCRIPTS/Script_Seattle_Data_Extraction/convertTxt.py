'''
This is a python script to convert Seattle traces from original txt files to sq3 files for input of the Elastic Pathing algorite hm.
Note that this script is specified for the original Seattle traces format in txt files.
Please refer to Elastic Pathing paper or our website for the link to the original Seattle dataset source.
'''

from sqlite3_query import Queryer as Q
import os
import sys
import math

# This is for the original testing. Now we use getDistNew to calculate the distance
def getDist(lat1, long1, lat2, long2):

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

# getDistNew is used to calculate the distance with lat. and long. pairs.
def getDistNew(lat1, long1, lat2, long2):


    # Convert latitude and longitude to 
    # spherical coordinates in radians.
    degrees_to_radians = math.pi/180.0
        
    # phi = 90 - latitude
    dlon = (long2 - long1)*degrees_to_radians
    dlat = (lat2 - lat1)*degrees_to_radians
    a = math.sin(dlat/2.0)*math.sin(dlat/2.0) + math.cos(lat1*degrees_to_radians)*math.cos(lat2*degrees_to_radians)*math.sin(dlon/2.0)*math.sin(dlon/2.0)
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))

    # Remember to multiply arc by the radius of the earth 
    # in your favorite set of units to get length.
    # in miles
    return c*3959


# parse the file and return the data matrix [time(ms), lat, lon, speed(mph)]
def toSql(filepath, dbpath, filename):
    pastSpeed = -1.0
    count = 0
    dbcount = 1
    db = Q(dbpath + '/' + filename + '_' + str(dbcount)+'.sq3')
    create1 = "CREATE TABLE IF NOT EXISTS 'gpstrace' ('latitude' NUMBER, 'longitude' NUMBER, 'time' NUMBER);"
    create2 = "CREATE TABLE IF NOT EXISTS 'speeds' ('speed' NUMBER, 'time' NUMBER);"
    delete1 = "delete from gpstrace;"
    delete2 = "delete from speeds;"
    db.execute(create1)
    db.execute(delete1)
    db.execute(create2)
    db.execute(delete2)
    for line in open(filepath, 'r'):
        # extract information from each line in the txt file
        count += 1
        if count == 2:
            # Start from second line in the file (note that the first line in the descriptions for each column in the txt file)
            # Also note that count could be reset later if a separate file is needed.
            output = line.split(',')
            pastLat = float(output[2])
            pastLong = float(output[3])
            time_part = output[1].split(' ')[0].split(':')
            pm_am = output[1].split(' ')[1]
            if pm_am == "AM" and time_part[0] == "12":
                time_part[0] = "0"
            if pm_am == "PM" and time_part[0] != "12":
                time_part[0] = str(int(time_part[0]) + 12)
            pastTime = int(time_part[0]) * 3600 * 1000 + int(time_part[1]) * 60 * 1000 + int(time_part[2]) * 1000
        elif count > 2:
            output = line.split(',')
            currentLat = float(output[2])
            currentLong = float(output[3])
            # capture and split device time
            time_part = output[1].split(' ')[0].split(':')
            pm_am = output[1].split(' ')[1]
            if pm_am == 'AM' and time_part[0] == '12':
                time_part[0] = "0"
            if pm_am == 'PM' and time_part[0] != '12':
                time_part[0] = str(int(time_part[0]) + 12)
            currentTime = int(time_part[0]) * 3600 * 1000 + int(time_part[1]) * 60 * 1000 + int(time_part[2]) * 1000
            #Seattle data have 5 seconds sampling rate. If the time is longer than 5 seconds, we should make a new trace with a new file
            if (pastTime + 5000) == currentTime:
               #Following does the data insertion into sq3 database and data interpolation to 1 second sampling rate for our program requirement
                currentSpeed = getDistNew(pastLat, pastLong, currentLat, currentLong) / 5.0 * 3600
                if pastSpeed < 0.0:
                    pastSpeed = currentSpeed
                t=pastTime
                for x in range(0, 5):
                    t = t + 1000 
                    insert1 = "insert or replace into 'gpstrace' (latitude,longitude,time) values (%s, %s, %d);\n" % (float(pastLat+(currentLat-pastLat)/5.0*(x+1.0)), float(pastLong+(currentLong-pastLong)/5.0*(x+1.0)), int(t))
                    insert2 = "insert or replace into 'speeds' (speed,time) values (%s, %d);\n" % (float(pastSpeed+(currentSpeed-pastSpeed)/5.0*(x+1.0)), int(t))
                    db.execute(insert1)
                    db.execute(insert2)
                pastTime = currentTime
                pastLat = currentLat
                pastLong = currentLong
                pastSpeed = currentSpeed
            else:
                db.closeDB()
                if count > 40:
                    dbcount = 1 + dbcount
                db = Q(dbpath + '/' + filename + '_' + str(dbcount)+'.sq3') 
                db.execute(create1)
                db.execute(delete1)
                db.execute(create2)
                db.execute(delete2)
                count = 1
                pastSpeed = -1.0
    db.closeDB()
    

def main():
    # if the input length is not valid, print out the usage notification
    if len(sys.argv) != 4:
        print "Usage: python convertTxt.py file destination_folder_path filename"
        exit(0)
    # get the file names and path
    file1 = sys.argv[1]
    fpath = sys.argv[2]
    fname = sys.argv[3]
    # convert to sql files
    toSql(file1, fpath, fname)

if __name__ == '__main__':
    main()
