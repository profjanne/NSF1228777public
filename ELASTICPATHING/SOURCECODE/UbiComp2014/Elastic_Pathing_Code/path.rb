################################################################################
# Support for tracking paths of Open Street Map nodes
################################################################################

require './path_decisions'

#Haversine distance in miles (used to find actual distances between GSP coordinates)
def haversine_mi(lat1, lon1, lat2, lon2)
  @d2r = Math::PI / 180.0
  
  dlon = (lon2 - lon1) * @d2r;
  dlat = (lat2 - lat1) * @d2r;
  a = Math.sin(dlat/2.0)**2 + Math.cos(lat1*@d2r) * Math.cos(lat2*@d2r) * Math.sin(dlon/2.0)**2;
  c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a));
  #Multiply by the radius of the earth (in miles here)
  return 3956 * c; 
end

#Node from open street maps. Have node id, latitude, longitude, and way ID.
#Some nodes actually are on multiple ways, but this class just stores the
#way ID from the way being traversed.
class Node
  attr_accessor :nid, :lat, :lon, :wid, :time

  def initialize(nid, lat, lon, wid = nil, time = nil)
    @nid = nid
    @lat = lat
    @lon = lon
    @wid = wid
    @time = time
  end

  #Distance between this node and another node
  def distance(other)
    return haversine_mi(@lat, @lon, other.lat, other.lon)
  end

  #To string function for printing
  def to_s()
    return "#{nid} (#{lat}, #{lon}) at #{time}"
  end
end

#Remember paths travelled, time duration until the next point is reached, etc
class Path
  attr_accessor :path, :turn_start, :unique_id, :hash_path
  attr_reader :max_err, :seq_err, :overall_err, :total_distance, :progress
  #Degrade TURN_POSSIBLE status the further from the speed inflection we travel
  @@MILES_PER_METER = 0.000621371
  def initialize(start)
    @path = [start]
    @unique_id = "0"
    #Segment progress
    @progress = 0
    @hash_path = {start.nid => [start.wid]}
    #False until a turn is possible from the speed profile.
    @can_turn = false
    #Remember the distance when a turn should have started for path quality
    #rating and pruning
    @turn_start = 0
    #The sequential or overal error, based upon the distances where turns
    #were made. Sequential error counts every distance delay or addition as
    #a positive impact upon error, whereas overall will let a negative delay
    #followed by a positive delay cancel out.
    #@seq_err is always positive, @overall_err is positive or negative
    @seq_err = 0.0
    @overall_err = 0.0
    @max_err = 0.0
    @tmp_err = 0
    @total_distance = 0.0;
    @last_turn_distance = 0.0
  end

  #Accessors for can_turn variable. Once a transition is made clear the variable.
  #offset from the calculated offset along this path
  def can_turn=(can)
    @can_turn = can
    #Remember when turning became possible
    @last_turn_distance = @total_distance
  end
  def can_turn
    @can_turn
  end


  #Multiple the current error by a given (or default) amount
  def downgradePath(modifier = 1.1)
    @seq_err *= modifier
    @overall_err *= modifier
  end

  def addPoint(node)
    #The possibility of turning if affected by distance from the speed inflection
    #Downgrade the can_turn variable
    #if (FUTURE_TURN_POSSIBLE == @can_turn)
      #@can_turn = TURN_POSSIBLE
    #else
      #@can_turn = NO_TURN
    #end
    @progress = -1 * node.distance(path[-1])
    puts "Starting progress to new node (#{node.nid}) -- distance is #{@progress}"
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
    #return (@hash_path.has_key?(node.nid)) and (@hash_path[node.nid].include?(node.wid))
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
    #copy.unique_id = @@path_id += 1
    puts "DEBUG: Just cloned and distance is #{copy.progress}"
    copy
  end

  def to_s()
    "ID #{@unique_id}: #{path.length} nodes, with distance #{@progress}" +
      "(total distance is #{@total_distance}) (error code is #{@err_code}," +
      "cum error is #{@overall_err}/#{@seq_err}/#{@max_err})\n" +
      path.join("\n")
  end
end


