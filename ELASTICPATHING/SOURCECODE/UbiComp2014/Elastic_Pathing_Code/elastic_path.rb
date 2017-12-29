################################################################################
# Support for tracking paths of Open Street Map nodes
# This version of a path keeps track of ``landmarks'' along the way. If the
# path needs to be corrected then only the distance since the last landmark
# is altered by some expansion or compression factor
#
# Landmarks occur when there is a possibility of a Type A or Type B error.
# See the path_decisions.rb file for descriptions of those errors.
# If the speed falls to zero then that 0 needs to be matched to an
# intersection. Once that is done, a landmark has been identified.
# Likewise, a turn in the path must have speed values that are slow enough to
# allow that turn. Once a match between speed values and the turn occurs
# a landmark has also been identified.
# When an error is found during pathing these past landmarks cannot move,
# so the distance coverered in the time between the landmarks must either
# be compressed, indicating that less distance was travelled than we estimated,
# or expaned, indicating that more distance was travelled than we estimated.
#
################################################################################

require './path_decisions'

require './node.rb'

# Landmarks are used to pinpoint visited points while pathing.
# Setting up the landmarks is when the error gets updated if there is any.
# Passed landmarks cannot change positions.

class Landmark
  attr_reader :distance, :time, :compression
  def initialize(distance, time, compression)
    #The distance along the path when this landmark was encountered
    @distance = distance
    @time = time
    #The compression factor applied to the distance travelled between
    #the previous landmark and this one
    @compression = compression
  end
end

#This class is to remember paths travelled and time duration until the next point is reached, etc
class ElasticPath
  #Need to remember the path of nodes and the landmarks passed
  #Also remember a 'unique id' that describes the turns on this path.
  #Also store a hash map to check if a node has been travelled on before.
  attr_accessor :path, :unique_id, :hash_path, :progress, :time_index, :landmarks
  attr_reader :max_err, :seq_err, :overall_err, :total_distance, :segment_dist, :speed_samples

  #Initialize with the starting node and the distance until it is reached

  @@navigator = nil
  def self.setNavigator(nav)
    @@navigator = nav
  end

  def self.setLogfile(logfile)
    @@logfile = logfile
  end

  def putlog(str)
    if (nil != @@logfile)
      @@logfile.puts str
    end
  end

  def initialize(start_node, distance, samples, change_intervals)
    #We cannot path without a navigator, so raise an error
    if (nil == @@navigator)
      raise "ElasticPath cannot be created without setting a navigator with ElasticPath.setNavigator"
    end
    @path = [start_node]
    @speed_samples = samples
    @time_index = 0
    @unique_id = "0"
    #Segment progress (negative until we reach the node at @path.last
    @progress = -1*distance
    #Distance travelled
    @total_distance = 0.0;
    @segment_dist = 0.0;
    @hash_path = {start_node.nid => [start_node.wid]}
    #Initialize the first landmark at the beginning
    @landmarks = [Landmark.new(0, 0, 1.0)]
    @seq_err = 0
    @overall_err = 0
    @max_err = 0
    @change_intervals = change_intervals
    @cur_interval = 0
  end

  def lastLandmarkTime
    return @landmarks.last.time
  end

  def curSegmentDistance
    return @segment_dist
  end

  def complete
    @time_index == @speed_samples.length
  end

  #Set a new landmark after an error is corrected.
  #The compression factor used determines the error value
  def setLandmark(compression)
    @landmarks.push Landmark.new(@segment_dist, @time_index, compression)
    #Set new error values
    err = @segment_dist/compression - @segment_dist
    if (err.abs > @max_err)
      @max_err = err.abs
    end
    @seq_err += err
    @overall_err += err.abs
    #Clear the segment distance since we are moving to the next landmark
    @segment_dist = 0.0
  end

  #Advance along the samples until a Type A or B error occurs or the path diverges
  def advanceUntilBranch()
    while (@time_index < @speed_samples.length)
      putlog "Advancing path #{@unique_id}. Starting at index #{@time_index} of #{@speed_samples.length}"
      #If speed is 0 or near 0, we should be close to an
      #intersection or a Type B error occurs.
      #The following two parameters 0.8 mph and 1 mph are all experimental values.
      #This set of parameters generally work well on filtering out speed samples near 0.
      if (@speed_samples[@time_index].speed < 0.8)
        putlog "Zooming through low speed section"
        while (@time_index < @speed_samples.length and
               @speed_samples[@time_index].speed < 1)
          @time_index += 1
        end
        at_intersection = @@navigator.pathIntersects(self).length > 1
        #If we have no more samples then this is the end, don't look for an intersection
        #Otherwise there needs to be an intersection close to this.
        if (@time_index < @speed_samples.length)
          if (at_intersection)
            #Set a landmark at this location with compression of 1.0 to indicate
            #no changes were necessary and continue pathing.
            setLandmark(1.0)
          else
            #Can attempt to correct the paths by expanding or shrinking the
            #path from the last landmark, but only if movement has occured.
            if (0 < segment_dist)
              backpath = rewindBError(self.clone, @@navigator)
              forepath = advanceBError(self.clone, @@navigator)
              #Return new possible paths
              return [backpath, forepath].compact
            end
        end
        else
          #Pathing finished here
          putlog "Path finished while going through low speed section."
          return [self]
    end
  end

      putlog "Progressing normally"
      #Advance the path here.
      sample = @speed_samples[@time_index]
      @progress += sample.movement
      #Although we handle overshoot below, the extra distance will always be assigned
      #to the next path so we can record it as part of the total distance immediately
      @total_distance += sample.movement
      @segment_dist += sample.movement

      #Advance the time index after processing the sample
      @time_index += 1

      #Choose a next location if the next node is reached
      if (0 < @progress)
        putlog "Reached a new node with id #{@path.last.nid} and coordinates #{@path.last.lat},#{@path.last.lon}"
        #In here, we do not consider the case when the U-turn passes through the same node as current node.
        #For most U-turn in the highway, the U-turn usually passes through a new node in the other side of the 
        #highway having the  opposite direction. However, there do exist some intersections with U-turn coming back to
        #the original node since not all the nodes in the OSM are well recorded and connected in the same way.
        next_nodes = @@navigator.possibleTurns(self)
      
        #following if statement is to fix the nil way ID for first node of the path.
        if ((@path.length==1)&&(@path.last.wid==nil))
          @path.last.wid=next_nodes.last.wid
        end

        #Sort the nodes by their way ID changes so that we can identify road changes easily
        next_nodes.sort!{|x,y| (x.wid-@path.last.wid).abs <=> (y.wid-@path.last.wid).abs}

        #If speed is faster than the maximum allowed speed for the turning angle then a Type A error occurs
        #Determine whether each path is viable.
        new_paths = []
        #Lanes of the current road
        start_lanes = @@navigator.lanes(@path.last.wid)
        putlog "Path #{@unique_id} reaches next node with #{next_nodes.length} choices"
        turn_idx = 0
        next_nodes.each{|node|
          #If this is the only option or the way is the same then this is the simple case
          #of a curving road
          way_changes = (next_nodes.length == 1 or node.wid == @path.last.wid)
          new_lanes = @@navigator.lanes(node.wid)
          if (@path.length < 2)
            turn_angle = 0.0
            prev_step_distance = 0.0
          else
            turn_angle = turnAngle(@path[-2], @path[-1], node)
            prev_step_distance = @path.last.distance @path[-2]
          end
          step_distance = @path.last.distance node
          r = turnRadius(start_lanes, new_lanes, way_changes, turn_angle, step_distance, prev_step_distance)
          safe_r = safeTurnRadius(sample.speed)
          putlog "Choice #{turn_idx}: ways are #{@path.last.wid} and #{node.wid} " +
           "(#{@@navigator.getWayname(@path.last.wid)} and #{@@navigator.getWayname(node.wid)}, " +
           "turn angle is #{turn_angle}, turn radius is #{r} and safe radius at speed #{sample.speed} is #{safe_r}"
          if (1 < @path.length and r < safe_r)
            #There might be an error of around 3 mph, so try again with that
            if (r < safeTurnRadius(sample.speed - 3))
              #Type A error (too fast for the turn)
              #Can attempt to correct the paths by expanding or shrinking the
              #path from the last landmark, but only if movement has occured.
              if (0 < segment_dist)
                new_paths.push rewindAError(self.clone, r, node)
                if (nil != new_paths.last)
                  if (new_paths.last.overall_err.nan?)
                    putlog "nan after rewind A"
                  end
                  new_paths.last.unique_id += "#{turn_idx}R"
                end
                new_paths.push advanceAError(self.clone, r, node, @@logfile)
                if (nil != new_paths.last)
                  if (new_paths.last.overall_err.nan?)
                    putlog "nan after advance A"
                  end
                  new_paths.last.unique_id += "#{turn_idx}A"
                end
              end
            end
          else
            new_paths.push self.clone
            new_paths.last.addPoint node
            new_paths.last.unique_id += "#{turn_idx}"
            #Set landmarks here if an actual turn is taken
            #because we cannot later adjust the speeds at this moment and
            #still make the turn
            #For way change, an alternative way is to compare the turning angle and have a threshold instead.
            if (node.wid != @path.last.wid)
              new_paths.last.setLandmark(1.0)
            end
          end
          turn_idx += 1
        }
        return new_paths.compact

      end

      #No branch, go on to the next point
end
    #If there are no more samples then this path is complete
    putlog "Path finished: no more samples"
    return [self]
end

  def addPoint(node)
    #New distance to next node is the distance past this one plus the distance
    #to the new node from the one we are currently passing
    @progress = @progress + -1 * node.distance(path[-1])
    putlog "Starting progress to new node (#{node.nid}) -- distance is #{@progress}"
    @path.push(node)
    if (not @hash_path.has_key? node.nid)
      @hash_path[node.nid] = []
    end
    @hash_path[node.nid].push node.wid
  end
  
  #Get the last two points, or last 1 if the path is too small
  def lastTwo()
    return [path[-2], path[-1]]
  end

  #True if this node was already passed
  def passed(node)
    if (@hash_path.has_key? node.nid)
      return (@hash_path[node.nid].include?(node.wid))
    else
      return false
    end
  end

  def clone
    copy = self.dup
    copy.path = self.path.map{|x| x}
    copy.hash_path = self.hash_path.clone
    copy
  end

  def to_s()
    "ID #{@unique_id}: #{path.length} nodes, with distance to next node #{@progress}" +
       " and total movement distance #{@total_distance} (" +
      "overall/seq/max errors are #{@overall_err}/#{@seq_err}/#{@max_err})"
  end
end


