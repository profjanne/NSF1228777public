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
