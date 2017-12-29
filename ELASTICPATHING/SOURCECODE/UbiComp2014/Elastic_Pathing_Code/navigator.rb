################################################################################
# Define the Navigator class.
# The navigator class directly uses OSM data from a SQL file, providing
# shortcuts to find adjacents nodes and so on.
################################################################################

require './node'
require 'sqlite3'
require './path_decisions'
class Navigator

  attr_accessor :log

  #Accepts the database name for the map data and a place to log events
  def initialize(db_name, log, turnLim)
    @map_data = SQLite3::Database.new(ARGV[1])
    @map_data.results_as_hash = true unless @map_data.results_as_hash
    @nodes = Nodes.new(@map_data,log)
    @ways = Ways.new(@map_data,log) 
    @log = log
    #Cache way speeds (for the get_speed method)
    @stored_speeds = {}
    @has_restrictions = false
    @map_data.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='restrictions';"){|r|
      @has_restrictions = true
      @turnLim=turnLim
    }
  end

  def getSpeedLimit(wid)
    speed = [1,100]
    @map_data.execute("SELECT type FROM ways WHERE wid = #{wid};"){|r| 
          @map_data.execute("SELECT minspd, maxspd FROM speedtype WHERE type = '#{r['type']}';") {|s|
            speed = [s['minspd'], s['maxspd']]
          }
        }
        return speed;
end
  #Get the number of lanes of a way. Defaults to 1 if the way is not known.
  def lanes(wid)
    num_lanes = 1
    @map_data.execute("SELECT lanes FROM lanes WHERE wid = #{wid};"){|r| 
      num_lanes = r['lanes'].to_i
    }
    return num_lanes
  end

  #Find the node closest to the given latitude and longitude
  def closest(lat, lon, bound)
    closest = 0
    close_dist = 100.0
    #No tolerance here...guess it's a global variable somewhere?
    close_id = @nodes.get_nearest_arr(lat,lon)[0][0]
    return Node.new(close_id, @nodes.get_lat(close_id), @nodes.get_lon(close_id))
  end

  #Find nodes that connect to this one
  def intersect(node)
    #Use adjacency list from the adjacencies table to look up adjacent nodes
    adjs = []
    @map_data.execute("SELECT wid, to_nid FROM adjacencies WHERE from_nid = #{node.nid};"){|r| 
      wid = r['wid'].to_i
      nid = r['to_nid'].to_i
      lat = @nodes.get_lat(nid)
      lon = @nodes.get_lon(nid)
      adjs.push(Node.new(nid, lat, lon, wid))
    }
    return adjs
  end

  #Find next possible points for a path
  def pathIntersects(p)
    cur = p.lastTwo()
    if (nil == cur[0])
      return intersect(cur[1])
    else
      #Get any nodes the intersect with cur[1] and is not cur[0]
      return intersect(cur[1]).select {|node| node.nid != cur[0].nid}
    end
  end

  #Find next possible points for a path
  def possibleTurns(p)
    cur = p.lastTwo()
    possible = []
      #if (cur[1].nid==104420844)
      #  puts "Turn restriction: #{@has_restrictions} way id: #{cur[1].wid}"
     #end
    if (nil == cur[0])
      possible = intersect(cur[1])
    else
      #Get any nodes the intersect with cur[1] and is not cur[0]
      possible = intersect(cur[1]).select {|node| not p.passed(node)}
      #Now only keep possible nodes where the movement is legal
        
      possible=possible.select{|node|
        legal = true
        #Multiple restrictions may apply to this road. The legality of the turn
        #is true only when they are all true.
        if (@has_restrictions)
          @map_data.execute("SELECT type from restrictions where nid=#{p.path.last.nid} " +
                            "and from_wid=#{p.path.last.wid}") {|r|
            restriction = r['type']
            #See if this transition is legal. If it isn't, set legal to false
            
            turning_angle=turnAngle(cur[0], cur[1], node)
            if ("only_straight_on" == restriction)
              #Any turn is wrong, only legal if the way does not change
              legal = (legal and ((p.path.last.wid == node.wid) or ((turning_angle<8) and (turning_angle>-8))))
                
                
               
            elsif ("only_right_turn" == restriction)
              legal = (legal and (turning_angle>8))
              
            elsif ("no_right_turn" == restriction)
              legal = (legal and (8 >= turning_angle))
              
            elsif ("only_left_turn" == restriction)
              legal = (legal and (-8 > turning_angle))
            elsif ("no_left_turn" == restriction)
              legal = (legal and (-8 <= turning_angle))
              
            elsif ("no_u_turn" == restriction)
              #A U-turn would lead back to the same way one a 2-way street
              #or on to the other side of the way on a divided street (but the wid
              #would change). Can either check the turn angle and look for
              #something far over 90 degrees or can check to see which ndoes
              #are closer.
              #U-turn must be a left turn
              if (turning_angle < -8)
                #If this isn't a U-turn then the distance from the last node to the
                #next node should be more than the distance from the current node
                #(the pivot) to the last node.
                legal = (legal and (cur[0].distance(node) > cur[1].distance(cur[0])))
                  
                
              end
            end
          }
        end #if @has_restrictions
        #Return the legal value from the block
        if (@turnLim==false)
        true
        else
          legal
        end
      }
    end
    
    return possible
  end

  #Find next possible points for a path of two points
  def nextPoints(nodea, nodeb)
    #Get any nodes the intersect with node b and is not node a
    return intersect(nodeb).select {|node| node.nid != nodea.nid}
  end

  #Get the expected speed of a way
  def get_speed(wid)
    if @stored_speeds.has_key? wid
      return @stored_speeds[wid]
    else
      speed = [1, 100]
      @map_data.execute("SELECT type FROM ways WHERE wid = #{wid};"){|r| 
        @map_data.execute("SELECT minspd, maxspd FROM speedtype WHERE type = '#{r['type']}';") {|s|
          speed = [s['minspd'], s['maxspd']]
        }
      }
      @stored_speeds[wid] = speed
      return speed
    end
  end

  def nodeFromID(nid, node_time = 0)
    first_node = nil
    @map_data.execute("SELECT latitude, longitude from nodes where id = #{nid} LIMIT 1;"){|r| 
      first_node = Node.new(nid, r[0].to_f, r[1].to_f, 0, node_time)
    }
    @map_data.execute("SELECT wid from ways where nid = #{nid} LIMIT 1;"){|r| 
      first_node.wid = r[0].to_i
    }
    return first_node
  end

  def getWayname(wid)
    @ways.get_name(wid)
  end

end

