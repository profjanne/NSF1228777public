################################################################################
# This program attempts to recreate a travelled path using just speed data.
# The program expects at least two arguments providing the sqlite file of
# a trace and the sqlite file with open street map data.
# Pathing information will be printed to a file named
# "manual_pathing_{trace name}.txt" where {trace name} is the trace's name.
################################################################################


# Node and way processing lib

require 'rubygems'
require './lib-NodeWay'
require 'sqlite3'
require './sample'
require './elastic_path'
require './path_decisions'
require './partial_path'
require './navigator'
require 'timeout'
require 'fileutils'

# Terminating the program

Signal.trap("SIGTERM") {
  puts "Exiting..."
  exit
}

Signal.trap("SIGINT") {
  puts "Exiting..."
  exit
}

# puts ARGV.length

if (ARGV.length != 2)
  puts "Usage: elastic_pathing <path SQLite file> <map SQLite file>"
  exit 0
end

# Set up logger file

LOG = Logger.new(STDOUT)

# Time interval threshold setting
DELTA_INTERVAL = 500

# Calculate 3 meters in miles for use in intersection timing

MILES_PER_METER = 0.000621371
THREE_METERS = 3*MILES_PER_METER

# Initialize error with negative value

error=-100

# 0 is for no speed limitation and no turn limitation
# 1 is for no turn limitation and speed limitation allowing speed to be no more than maximum way speed + 10 mph.
# 2 is for no turn limitation and speed limitation allowing speed to be no more than maximum way speed + 15 mph.
# 3 is for no turn limitation and speed limitation allowing speed to be no more than maximum way speed + 20 mph.
# 4 is for no turn limitation and speed limitation allowing speed to be no more than maximum way speed + 25 mph.
# 5 is for no speed limitation but with turn limitation
# 6 is for turn limitation and speed limitation allowing speed to be no more than maximum way speed + 10 mph
# 7 is for turn limitation and speed limitation allowing speed to be no more than maximum way speed + 15 mph
# 8 is for turn limitation and speed limitation allowing speed to be no more than maximum way speed + 20 mph
# 9 is for turn limitation and speed limitation allowing speed to be no more than maximum way speed + 25 mph

# use case 3 for speed limitation + 20 mph version. So far, this gives the best results.

loop=[3]

# When there are more than one element in the 'loop', the program will run through each case and select the
# one with least overall error as the solution path.
# loop=[2,7,3,8,2,7,1,6,0,9]

loop.each{ |elem|
  turnLimitation=false
  speedLimitation=false
  exceeding_max_speed=10

# set up parameters for different cases (from 0 to 9 as describe above)
  if (elem==0)
    speedLimitation=false
    turnLimitation=false
  elsif (elem==1)
    turnLimitation=false
    speedLimitation=true
    exceeding_max_speed=10
  elsif (elem==2)
    turnLimitation=false
    speedLimitation=true
    exceeding_max_speed=15
  elsif (elem==3)
    turnLimitation=false
    speedLimitation=true
    exceeding_max_speed=20
  elsif (elem==4)
    turnLimitation=false
    speedLimitation=true
    exceeding_max_speed=25
  elsif (elem==5)
    turnLimitation=true
    speedLimitation=false
  elsif (elem==6)
    turnLimitation=true
    speedLimitation=true
    exceeding_max_speed=10
  elsif (elem==7)
    turnLimitation=true
    speedLimitation=true
    exceeding_max_speed=15
  elsif (elem==8)
    turnLimitation=true
    speedLimitation=true
    exceeding_max_speed=20
  elsif (elem==9)
    turnLimitation=true
    speedLimitation=true
    exceeding_max_speed=25
  end
  
begin

# set up timer to force stop after 60 seconds. Usually, the result will come out in less than 10 seconds.
# If the process is still running after 60 seconds, there must be something wrong with the input data.
# (Possible reason would be that none of the explored paths has a good match to the speed data.)

Timeout::timeout(60){

# CREATE FILE
# This is a temporary file storing the information while running. The final file will be copied to manual_pathing_(track name).txt

@logfile = File.new("manual_pathing_OLD_#{ARGV[0].split("/")[-1].split(".")[0]}.txt", "w")

# Puts a String to the File

def putlog(str)
  @logfile.puts str
end


# Open the MapDB and instantiate the objects that manage it.

@path_data = SQLite3::Database.new(ARGV[0])
navigator = Navigator.new(ARGV[1], LOG, turnLimitation)
ElasticPath.setNavigator(navigator)
ElasticPath.setLogfile(@logfile)

#Set a clipping interval and cut the points occuring faster than this rate.

speeds = []
delta_idx = 0

#Read in speed statistics

@total_distance = 0
@total_time     = 0
speed_rundown = 0

@path_data.execute("SELECT speed, time from speeds ORDER BY time ASC;"){|r| 
  delta = 0
  speed_delta = 0
  cur_time = r[1].to_i
  cur_speed = r[0].to_f
  speed_minimum = 0

  #See if a delta speed is available

  if (speeds.empty? or speeds[-1].time + DELTA_INTERVAL <= cur_time)
    if (not speeds.empty?)
      delta = cur_time - speeds[-1].time
      speed_delta = cur_speed - speeds[-1].speed
      @total_time += delta
    end

    #This only applies to unsmoothed data.

    if (0 < speed_delta)
      #Clear speed rundown and record the minimum if we just rose up from the bottom
      speed_minimum = speed_rundown
      speed_rundown = 0
    else
      speed_rundown += speed_delta
      speed_minimum = 0
    end

    #Calculate the movement from this sample: convert miles per millisecond to mph

    movement = (delta)*cur_speed/(60*60*1000.0)
    #Total distance in miles
    @total_distance += movement
    speeds.push Sample.new(cur_time, cur_speed, movement, speed_delta, delta/1000.0, speed_minimum)
  end
}

puts "Total time (ms) and distance (miles) are #{@total_time} and #{@total_distance}"
avg_speed = speeds.inject(0.0){|avg, x| avg + x.speed / speeds.length.to_f}

################################################################################
#Build a turn probability table with a mapping from time intervals to
#speed change types (speed increasing, speed decreasing, speed stable)
#First get all of the stable speed values above 15mph

stable_speeds = speeds.select{|sample|
  sample.speed > 15 and sample.speed_delta.abs < 2
}

#Now that samples are stable we need to cut the speeds into sections

segments = []
while (not stable_speeds.empty?)
  ref_speed = stable_speeds.first.speed
  segment = stable_speeds.take_while{|sample| (ref_speed - sample.speed).abs <= 5}
  stable_speeds = stable_speeds.drop(segment.length)
  segments.push(segment)
end

class SpeedInterval
  attr_accessor :start, :stop, :speed
  def initialize(start, stop, speed)
    @start = start
    @stop  = stop
    @speed = speed
  end
  def to_s
    "(#{@start}, #{@stop}) #{@speed}"
  end
end

#Now compact the segments into time intervals with average speeds

speed_intervals = segments.map{|segment|
  #Average the speed and record the first and last times
  segment_avg = segment.inject(0.0){|avg, x| avg + x.speed / segment.length.to_f}
  SpeedInterval.new(segment.first.time, segment.last.time, segment_avg)
}

#Get rid of any segments that last for less than 10 seconds
#This is trying to get rid of ramp and transient accelerations/decelerations

speed_intervals = speed_intervals.select{|interval|
  interval.stop - interval.start > 10*1000.0
}

#Now anneal sections that are within 5mph of each other. Smooths
#out intervals after the transient sections were removed
#Each labelled interval has its start and stop time, and the speed at the
#beginning of the interval

labelled_intervals = [speed_intervals.first]

speed_intervals.each_index{|i|
  if (0 < i)
    #If within 5 mph then anneal
    if (5 > (speed_intervals[i-1].speed - speed_intervals[i].speed).abs)
      #Change the last time of current interval to the last time of the new interval
      labelled_intervals.last.stop = speed_intervals[i].stop
      putlog "Adjusting interval with start and stop #{labelled_intervals.last.start} and #{labelled_intervals.last.stop}"
    else
      #Add a new interval
      labelled_intervals.push speed_intervals[i]
      putlog "Adding new interval with start and stop #{labelled_intervals.last.start} and #{labelled_intervals.last.stop}"
    end
  end
}

#Expected changes happen between the labelled intervals

@change_intervals = labelled_intervals[1..-1].zip(labelled_intervals).map{|second, first|
  #Transition to second.speed during the interval from first.stop to second.start
  SpeedInterval.new(first.stop, second.start, second.speed)
}

putlog "Intervals are:"
speed_intervals.each{|x|
  putlog "#{x}, (duration is #{(x.stop - x.start)/1000.0} seconds)"
}

putlog "Labelled intervals are:"
labelled_intervals.each{|x|
  putlog "#{x}, (duration is #{(x.stop - x.start)/1000.0} seconds)"
}

putlog "Change intervals are:"
@change_intervals.each{|x|
  putlog "#{x}, (duration is #{(x.stop - x.start)/1000.0} seconds)"
}

#Now correct the end of that path. Find the last stable interval and use that as
#the endpoint. This should clip out maneuvering in parking lots and such.
#Want all points up to and including labelled_intervals.last.stop

speeds = speeds.take_while{|s| s.time <= labelled_intervals.last.stop}

#Return nil if no speed transition is expected, otherwise return a
#SpeedInterval with the time interval and the expected speed to turn into

def expectedTransition(time)
  @change_intervals.select {|interval|
    interval.start <= time and interval.stop >= time
  }.first
end

################################################################################
#Convenience function to normalize distance correction errors to
#time correction errors
#This function was used in the testing stage.

def normalizeDistance(dist)
  dist * @total_time / @total_distance
end


#Returns true if this node is reachable in noticeably less time
#This function was used in the testing stage.
#Although following code is not calling this anymore, 
#it may be useful for future addition.

@arrival_times = {}
def tooSlow(node, time)
  if (@arrival_times.has_key?([node.nid, node.wid]))
    puts "Comparing time for #{node}: previously #{@arrival_times[[node.nid, node.wid]]}, now #{time}"
    #Give 10 seconds plus 1.2 times previous best
    return (10000+1.2*@arrival_times[[node.nid, node.wid]] < time)
  else
    #puts "Saving new arrival time for #{node} as #{time}"
    @arrival_times[[node.nid, node.wid]] = time
    return false
  end
end

################################################################################
#Pathing begins here!
#First we find the starting point and then we start pathing.
################################################################################

start_gps = []
end_gps = []
gps_trace = []

@path_data.execute("SELECT latitude, longitude from gpstrace order by time asc limit 1;"){|r| 
  start_gps = [r[0].to_f, r[1].to_f]
}

@path_data.execute("SELECT latitude, longitude from gpstrace WHERE time <= #{speeds.last.time} order by time desc limit 1;"){|r| 
  end_gps = [r[0].to_f, r[1].to_f]
}

#Store [time, lat, lon] tuples

@path_data.execute("SELECT time, latitude, longitude from gpstrace WHERE time <= #{speeds.last.time} order by time;"){|r| 
  gps_trace += [[r[0].to_i, r[1].to_f, r[2].to_f]]
}

first_node = nil
has_path = false
has_firstnode = false
first_time = nil

#See if there is a nodepath or firstnode table.
#Don't use the raw gps point, this leads to hilarity (eg. going down train tracks)

@path_data.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='nodepath';"){|r|
  has_path = true
}

@path_data.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='firstnode';"){|r|
  has_firstnode = true
}

if (has_path)
  @path_data.execute("SELECT nid, latitude, longitude from nodepath order by time asc limit 1;"){|r| 
    first_node = Node.new(r[0].to_i, r[1].to_f, r[2].to_f)
    first_node.wid=navigator.nodeFromID(r[0].to_i,speeds.first.time).wid
  }
elsif (has_firstnode)
  first_nid  = nil
  @path_data.execute("SELECT time, \"node id\" from firstnode;"){|r| 
    puts "Getting firstnode results: #{r}"
    first_time = r[0].to_i
    first_nid = r[1].to_i
  }
  if (nil != first_nid)
    puts "Assigning first node"
    first_node = navigator.nodeFromID(first_nid, speeds.first.time)
  end
  puts "Firstnode is #{first_node}"
end


if (nil == first_node)
  putlog "Error -- could not find a close starting node."
  exit
end

#Drop samples from before the new starting time if we needed to
#advance along several nodes to find a OSM node match.

if (nil != first_time)
  speeds = speeds.drop_while{|s| s.time < first_time}
  gps_trace = gps_trace.drop_while{|s| s[0] < first_time}
  #Re-find the first GPS coordinate
  @path_data.execute("SELECT latitude, longitude from gpstrace where time = #{speeds[0].time};"){|r| 
    start_gps = [r[0].to_f, r[1].to_f]
  }
end

#Distance from the first GPS coordinate to the first OSM point

first_distance = haversine_mi(start_gps[0], start_gps[1], first_node.lat, first_node.lon)
putlog "Starting from first node #{first_node} with wid #{first_node.wid}"

#Start off with a single path

cur_paths = [Path.new(first_node)]
@total_moved = 0

#####################################################################################
#False until the beginning of a turn when @turn_active becomes true.
#Turns false again when the turn ends. Paths are checked at the falling
#edge to make sure they completed their turn.

@turn_active = false

def notifyPathDrop(path, reason)
  @logfile.putlog "Dropping dead path (#{reason})\nPath was #{path}."
  path.path.each{|n|
    @logfile.putlog "#{n.lat}, #{n.lon}"
  }
end

def makeNextPath(cur_path, node, move, err)
  newp = cur_path.clone
  newp.addPoint(node)
  newp.err_code = err
  return newp
end

#The minimum distance to different node ids. Used to prune.

min_dist_to = {}


################################################################################
#This is code to make plots for papers.
#Print out all nodes explored at this level of progress.

def printPlottable(progress, partial_paths)
  #Keep a map of already printed nodes to avoid making a huge output file.
  printed = {}
  partial_paths.each {|ep|
    ep.path.each {|node|
      if (not printed.has_key? node)
        putlog "PLOT EXPLORED #{progress} #{node.lon} #{node.lat}"
        printed[node] = true
      end
    }
  }
end

################################################################################
# This function is to get the maximum allowed speed in this "way"

@stored_speeds = {}
def get_speed(wid,nav)
  if @stored_speeds.has_key? wid
    return @stored_speeds[wid]
  else
    speed = nav.getSpeedLimit(wid)
    @stored_speeds[wid] = speed
    return speed
  end
end


################################################################################
#Pathing with Priority First Search
################################################################################
#Create a queue (sorted by error) to store each possible path.
#Explore the top path until its error increases to over that of the next path
#Once a path completes it is the best fit path (or tied with best fit)
#Continue looping until the best incomplete path is worse than our desired
#quality relative to the first path

completed_paths = []
selection_ratio = 1.1
partial_paths = [ElasticPath.new(first_node, first_distance, speeds, @change_intervals)]
cur_best_distance = partial_paths.first.total_distance
last_reported = 0

#Keep going unless we don't have any paths and while there are
#no results, or while the partial results might be within the
#selection ratio of the already completed ones

while (not partial_paths.empty? and
       (completed_paths.empty? or 
          partial_paths.last.overall_err.abs < selection_ratio*completed_paths.first.overall_err.abs))

  putlog "There are now #{partial_paths.length} partial paths and #{completed_paths.length} completed ones."

  #Sort the paths by descending error

  partial_paths.sort!{|x,y| y.overall_err.abs <=> x.overall_err.abs}

  #Print out path at different levels of progress (25%, 50%, 75%, 100%)

  cur_best_distance = partial_paths.first.total_distance

  if ((4*cur_best_distance/@total_distance).to_i > last_reported)
    last_reported = (4*cur_best_distance/@total_distance).to_i
    printPlottable(((4*cur_best_distance/@total_distance).to_i)*0.25, partial_paths)
  end

  putlog "Path choices are:"
  partial_paths.map{|ep| putlog ep}

  #Advance the best path until its error changes
  #Since this path will branch, remove the parent path first.
  #It will be replaced with its branching children

  best_path = partial_paths[-1]
  partial_paths.pop
  speeding=best_path.speed_samples[best_path.time_index].speed

  # if speedLimitation option is turned on, speed exceeds the limitation, (speed is not decreasing), 
  # and maximum allowed speed from OSM DB is greater than 20 mph, we should drop this path. It is not one of possible paths.

  if (true==speedLimitation and 1<best_path.path.length and 

  # The following line (condition for speed is not decreasing) should be commented out for New Jersey (sub-urban) dataset and
  # uncommented for the Seattle (urban) dataset for the best results through our testing. Therefore, depending on the driving
  # environment and driving habits, including this condition may improve or decrease the prediction accuracy.

       #best_path.speed_samples[best_path.time_index].speed_delta>0 and

       get_speed(best_path.path.last.wid,navigator)[1]+exceeding_max_speed< speeding and 
        20 < get_speed(best_path.path.last.wid, navigator)[1])

           putlog "way too fast, going #{speeding} but limit is #{get_speed(best_path.path.last.wid,navigator)[1]}"
           puts "way too fast, going #{speeding} but limit is #{get_speed(best_path.path.last.wid,navigator)[1]}"
  else    

    # Advance the best path and store the newly explored paths to the corresponding group.

    new_paths = best_path.advanceUntilBranch
    finished = new_paths.select{|ep| ep.complete}
    unfinished = new_paths.select{|ep| not ep.complete}
    partial_paths.concat unfinished
    completed_paths.concat finished

    # Sort the paths corresponding to the error, and get ready for the next iteration.

    partial_paths.sort!{|x,y| y.overall_err.abs <=> x.overall_err.abs}

  end
end

# Print out all the paths

printPlottable(1.0, partial_paths + completed_paths)
putlog "Finished... partial paths has #{partial_paths.length} elements"
cur_paths = completed_paths

putlog "Pathing complete."
putlog "There are #{cur_paths.length} remaining paths!"
putlog "Error #{cur_paths.first.overall_err}"
end_lat = end_gps[0]
end_lon = end_gps[1]
end_node = Node.new(0, end_lat, end_lon, 0)

#Sort by ascending error
#Print out the best possible path from Elastic Pathing algorithm

cur_paths.sort!{|x,y| x.overall_err.abs <=> y.overall_err.abs}
  puts "best path:"
cur_paths.each_index{|i|
  path = cur_paths[i]
  putlog "Path #{i} is #{path}"
  if (nil != path)
    putlog "Dist is #{path.path.last.distance(end_node)} miles (after moving #{@total_distance} miles) ending at (#{path.path[-1].lat}, #{path.path[-1].lon})"
    if (i==0) 
      @strinNew = "Dist is #{path.path.last.distance(end_node)} miles (after moving #{@total_distance} miles) ending at (#{path.path[-1].lat}, #{path.path[-1].lon})"
      end
    putlog "Path coordinates were:"
    path.path.each{|n|
      putlog "FinalPath #{i} #{n.lat}, #{n.lon}"
      if (i==0)
        puts "#{n.lat}, #{n.lon}"
      end
    }
    
  end
}

putlog "Expected end point is (#{end_gps[0]}, #{end_gps[1]})"

# Print out the ground truth path with the actual GPS trace.

gps_trace = gps_trace.drop_while{|s| s[0] < first_time}
  puts "GPSTrace"
gps_trace.each{|triple|
  putlog "GPSTrace #{triple[0]} #{triple[1]}, #{triple[2]}"
  puts "#{triple[1]}, #{triple[2]}"
}

puts @strinNew

#Extract important results to the last line.

putlog "Track Name, Total Distance, Endpoint Error, Overall error...all in miles"
putlog "#{ARGV[0].split("/")[-1].split(".")[0]}, #{@total_distance}, #{cur_paths.first.path.last.distance(end_node)}, #{cur_paths.first.overall_err}"
@logfile.close

#Copy the info into the final file if the solution with this particular set of parameters is better than before (overall_err is less than minimum error).

if ((cur_paths.length>0) and (error==-100 or cur_paths.first.overall_err<error))
  FileUtils.cp("manual_pathing_OLD_#{ARGV[0].split("/")[-1].split(".")[0]}.txt","manual_pathing_#{ARGV[0].split("/")[-1].split(".")[0]}.txt")
  error=cur_paths.first.overall_err
end
}

# catch the exception if time is out (more than 60 seconds)

rescue Exception=>e
  puts e
  #exit 0
end

}


#To pull out the best predicted path do following:
#grep "FinalPath" manual_pathing_(track_name).txt | awk '{print $3 " " $4}' > predicted_trace_(track_name).txt

#To pull out the ground truth path do following:
#grep "GPSTrace" manual_pathing_(track_name).txt | awk '{print $3 " " $4}' > ground_truth_trace_(track_name).txt

#To put the important results from all traces into a file, do following:
#tail -n 1 manual_pathing_(track_name).txt >> Results_Collection.txt

