#!/usr/bin/ruby
#This was the first library. It's meant to serve and an interface to the database. The Nodes and ways object can be instatied with 
#a DB object and all the methods used to manipluate maps. 
#Run as a standalone it returns the closest node to the center and the ways that contain it for map testing purposes


#My libraries
require './lib-Dist'

#SQL
require 'sqlite3'

#Logging
require 'logger'

#logging
require 'logger'

#option parseing
require 'optparse'

class NoNodesInTolerance < StandardError
	#A Custom expection for passing a message to the container class that the contained class wasn't able to find nodes within the Tolerance Distance
end

class Node_Buffer
	#A class for containing nodes that are not in a MAP DB. This should not be instantiated
	def initialize (maxnid, log)
		#maxnid is an integer, log is a logger object Logger.new(STDOUT)
		@maxnid = maxnid
		@log = log
		@nodes_buff = Array.new()
	end

	def fill_buffer(nodes)
		#nodes should be an array of 3 tuples nid/lat/lon
		@nodes_buff += nodes
		buff_max = @nodes_buff.map{|x| x[0]}.max
		@maxnid = buff_max if @maxnid < buff_max
		@log.debug("node_buffer: added #{nodes.length} to the buffer from trace db")
	end		

	def add_node(lat,lon)
		#lat,lon are floats. Adds a node to the list of known nodes. Does NOT modify the Database.
		@maxnid += 1
		@nodes_buff.push([@maxnid,lat,lon])
		@log.debug("add_node: NID max is now #{@maxnid}, there are now #{@nodes_buff.length} nodes in the buffer")
		return @maxnid
	end

	def get_lat(nid)
		#nid is an integer, returns the lat field of node
		tmp = @nodes_buff.select{|x| x[0] == nid}.first
		return tmp.nil? ? nil : tmp[1]
	end

	def get_lon(nid)
		#nid is an integer, returns the lat field of node
		tmp = @nodes_buff.select{|x| x[0] == nid}.first
		return tmp.nil? ? nil : tmp[2]
	end

	def get_dist_arr(lat,lon)
		#lat/lon are two floats, returns an array of nid,distance. 
		return @nodes_buff.map{|x| [x[0],Tools.latlondist(lat,lon,x[1],x[2])]}
	end
	
	def get_id(lat,lon)
		#lat and lon are floats, returns the id of a node that matches
		tmp = @node_bug.select{|x| x[1] == lat and x[2] == lon}.first
		return tmp.nil? ? nil : tmp[0]
	end

	def get_size()
		#returns buffer size
		return @nodes_buff.length
	end

	def dump_buffer()
		#returns the buffer contents for storage as an array of nid/lat/lon
		return @nodes_buff
	end
end

class Node_SQL
  attr_reader :minlat,:maxlat,:minlon,:maxlon,:maxnid
  #Node SQL interface, Pulls Nodes lats and lons from the sql container also stores bounds of the nodes. This should not be instantiated.
  def initialize (db, log)
    #db is a sql database object (properly SQLite3::Database.new(dbname), log is a logger object Logger.new(STDOUT)
    @db = db
    @db.results_as_hash = true unless @db.results_as_hash
    @log = log
    count = nil
    db.execute("SELECT COUNT(id) from nodes;"){|r| count = r['COUNT(id)']}
    @log.info("Node_SQL:Number of nodes in the map DB #{count}")
    @db.execute("SELECT latitude,longitude FROM bounds WHERE name = 'min';"){|r| 
      @minlon = r['longitude'].to_f 
      @minlat = r['latitude'].to_f 
    }
    @db.execute("SELECT latitude,longitude FROM bounds WHERE name = 'max';"){|r| 
      @maxlon = r['longitude'].to_f 
      @maxlat = r['latitude'].to_f 
    }
    @db.execute("SELECT MAX(id) FROM nodes;"){|r|
      @maxnid = r['MAX(id)'].to_i
    }
    @cur_node = Array.new()
    #Prepare some sql statement
    @lat_lon_query = @db.prepare("SELECT latitude,longitude FROM nodes WHERE id = ? LIMIT 1;")
    @id_query = @db.prepare("SELECT id FROM nodes WHERE latitude = ? AND longitude = ?;")
  end

  def close()
    @lat_lon_query.close()
    @id_query.close()
  end

	def update_curnode(id)
		#id is an integer
		#added internal function so that we only have to do 1 lookup, but preserved the interface
		lat = nil
		lon = nil
    @lat_lon_query.execute!(id) {|r| 
      lat = r[0].to_f
      lon = r[1].to_f
		}
		#@log.debug("#{lat},#{lon} was the lat for current #{id}")
		@cur_node = [id,lat,lon]
		raise "No lat,lon found for nid#{id}" if lat.nil? or lon.nil?
		return true
	end
	

	def get_lat(id)
		#id is an integer
		update_curnode(id) if @cur_node[0] != id
		return @cur_node[1]
	end
	
	def get_lon(id)	
		#id is an integer
		update_curnode(id) if @cur_node[0] != id
		return @cur_node[2]
	end

	def get_id(lat,lon)
		#lat and lon are floats
		id = nil
		@id_query.execute!(lat,lon){|r| id = r[0].to_i}
		@log.debug("#{id} mapped to #{lat},#{lon}")
		raise "No id found for lat #{lat},lon #{lon}" if id.nil?
		return id
	end

  def get_adjacent_arr(nid)
    result = []
    puts "Nid is #{nid}"
    @db.execute("SELECT wid, to_nid FROM adjacencies WHERE from_nid = #{nid};"){|r|
      result.push(r['to_nid'].to_i)
    }
    return result
  end

	def get_dist_arr(lat,lon, box = 0.005)
		#lat and lon are floats
		#Returns an array of nodes,distances ordered by distance
		retries =  1
		begin 
			#find a big bounding box
			ulat = lat.abs + box
			ulon = -(lon.abs - box)
			llat = lat.abs - box
			llon = -(lon.abs + box)
			dist = Tools.latlondist(ulat,ulon,llat,llon)
			@log.debug("Attempt #{retries}: Box was set to #{dist} with borders #{ulat},#{ulon},#{llat},#{llon}")
	
			near = Array.new()
			@db.execute("SELECT id,latitude,longitude FROM nodes WHERE latitude BETWEEN #{llat} AND #{ulat} AND longitude BETWEEN #{llon} AND #{ulon};"){|r| 
				near.push([r['id'].to_i,r['latitude'].to_f,r['longitude'].to_f])
			}
			@log.debug("number of near points #{near.length}")
			raise NoNodesInTolerance, "Can't find any points within the tolerance" if near.empty?
		rescue NoNodesInTolerance => e
			box += 0.005
			retry if (retries += 1) < 3
			@log.warn("Node_SQL.get_dist_arr: No nodes found within tolerance in the Database")
			return near
		end

		return near.map{|x| [x[0],Tools.latlondist(lat,lon,x[1],x[2])]}
	end

	def to_s()
		#this should be find because it's all strings
		return @db.execute("SELECT id FROM nodes;").flatten.inject(String.new()){|m,s| m + "#{s},"} 
	end

end

class Nodes
	#A container class for the Node_sql and Node_buffer class
	#This class unifies the interface and checks the buffer before the sql. This is the only class that should actually be instantiated
  	def initialize (db, log)
		#db is a sql database object (properly SQLite3::Database.new(dbname), log is a logger object Logger.new(STDOUT)
		@node_sql = Node_SQL.new(db,log)
		@node_buffer = Node_Buffer.new(@node_sql.maxnid, log)
		@minlat = @node_sql.minlat
		@minlon = @node_sql.minlon
		@maxlat = @node_sql.maxlat
		@maxlon = @node_sql.maxlon
		@maxnid = @node_sql.maxnid
	end
	attr_reader :minlat,:maxlat,:minlon,:maxlon,:maxnid

  def close()
    @node_sql.close()
  end

	def add_node(lat,lon)
		#lat/lon are floats. adds a node to the buffer, wil generate an id and return it as a value
		return 	@node_buffer.add_node(lat,lon)
	end

	def get_lat(nid)
		#nid is an integer. get latitude for a given node id, checks the buffer first and if that fails then checks the database
		tmp_lat = @node_buffer.get_lat(nid)
		return tmp_lat unless tmp_lat.nil?
		return @node_sql.get_lat(nid)
	end

	def get_lon(nid)
		#nid is an integer. get latitude for a given node id, checks the buffer first and if that fails then checks the database
		tmp_lon = @node_buffer.get_lon(nid)
		return tmp_lon unless tmp_lon.nil?
		return @node_sql.get_lon(nid)
	end

  def get_adjacent_arr(nid)
    #Get the adjacent nodes of a given node
    return @node_sql.get_adjacent_arr(nid)
  end

	def get_nearest_arr(lat,lon)
		#lat/lon are floats. check the map and buffer for nodes close to the given lat/lon returns and ordered list tuple of lat/lon/distance 
		buffer = @node_buffer.get_dist_arr(lat,lon)
		sql = @node_sql.get_dist_arr(lat,lon)
		near = buffer + sql
		raise NoNodesInTolerance, "No nodes can be found within tolerance from buffer or database" if near.empty?
		#This should return the nodes in size order with out knowledge of their source origin. At this points all nodes should be "equal"
		return near.sort{|x,y| x[1]<=>y[1]}
	end

	def get_buffer_size()
		#retuns the number of elements in the buffer
		return @node_buffer.get_size()
	end

	def get_id(lat,lon)
		#lat and lon are floats, check to see if a given lat/lon pair is an exact match for a given node. Returns the nid if found. 
		tmp_id = @node_buffer.get_id(lat,lon)
		return tmp_id unless tmp_id.nil?
		return @node_sql.get_id(lat,lon)
	end

	def dump_buffer()
		#returns an array of nid/lat/lon tuples that is the contents of the node buffer. 
		return @node_buffer.dump_buffer()
	end

	def fill_buffer(tdb)
		#tdb is a sqllite object (SQLite3::Database.new), populates the buffer with values from the database
		fill = Array.new()
		tdb.results_as_hash = true unless tdb.results_as_hash
		tdb.execute("SELECT * FROM gnodes"){|r| fill.push([r['id'].to_i,r['latitude'].to_f,r['longitude'].to_f])}
		@node_buffer.fill_buffer(fill)
	end
end

class Way_Buffer
	#A class for modified ways that differ from the map or new ways that may need to be created
	def initialize (maxwid,log)
		@maxwid = maxwid
		@log = log
		@way_buff = Array.new()
	end

	def fill_buffer(ways)
		#populates the buffer with values from the array expects 2 tuple of wid (integer) / nids [array of integers]
		@way_buff += ways
		buff_max = @way_buff.map{|x| x[0]}.max
		@maxwid = buff_max if @maxwid < buff_max
		@log.debug("Way_buffer: added #{ways.length} to the buffer from trace db")
	end

	def add_new_wid(nodelist)
		#nodelist is an array of interger node ids. Adds a way to the list of known ways. Does NOT modify the Database.
		@maxwid += 1
		@way_buff.push([@maxwid,nodelist])
		@log.debug("add_new_wid: WID max is now #{@maxwid}, there are now #{@way_buff.length} ways in the buffer")
		return @maxwid
	end

	def add_mod_wid(nodelist,wid)
		#nodelist is an array of interger node ids. wid is a known way id that is being modified. Adds a way to the list of known ways. Does NOT modify the Database.
		@way_buff.push([wid,nodelist])
		@log.debug("add_new_wid: added modified way #{wid}, there are now #{@way_buff.length} ways in the buffer")
		return wid
	end

	def wids_contain(nid)
		#nid is an interger node id, retuns an array of way ids that contain a given node id
		return @way_buff if @way_buff.empty?
		return @way_buff.map{|x| x[1].include?(nid) ? x[0] : nil}.compact
	end

	def get_nids(wid)
		#wid is an interger way id, returns the list of node ids that match to a given way id
		return @way_buff if @way_buff.empty?
		#shouldn't be multipiles so this drops one array level
		tmp_nids = @way_buff.select{|x| x[0] == wid}.first
		return tmp_nids.nil? ? Array.new(): tmp_nids[1]
	end

	def get_size()
		#return the buffer length
		return @way_buff.length
	end

	def get_wids()
		#returns a list of known Way Ids
		return @way_buff.map{|x| x[0]}
	end

	def has_id?(id)
		#id is an integer, return true if there this id is in the buffer
		return @way_buff.map{|x| x[0]}.include?(id)
	end

	def dump_buffer()
		#returns the buffers contents as an array of 2 tuples wid/nid
		dump = Array.new()
		@way_buff.each{|x| x[1].each{|nid| dump.push([x[0],nid])}}
		return dump
	end
end

class Way_SQL
		attr_reader :maxwid
	#Way SQL interface. Queries the Database for various Way information 
	def initialize (db,log)
		#db is a sql database object (properly SQLite3::Database.new(dbname), log is a logger object Logger.new(STDOUT)
		@db = db
		@db.results_as_hash = true unless @db.results_as_hash
		@log = log
		wids = Array.new()
		@db.execute("SELECT DISTINCT wid FROM ways;"){|r| wids.push(r['wid'].to_i)}
		@log.info("Number of ways #{wids.length}")
		@maxwid = wids.max
		@wids_query = @db.prepare("SELECT DISTINCT wid FROM ways;")
		@contain_query = @db.prepare("SELECT wid FROM ways WHERE nid = ? AND NOT type = 'NotHighWay' ;")
		@nids_query = @db.prepare("SELECT nid FROM ways WHERE wid = ?;")
		@name_query = @db.prepare("SELECT name FROM ways WHERE wid = ?;")
		@type_query = @db.prepare("SELECT type FROM ways WHERE wid = ?;")
	end

  def close()
		@wids_query.close()
		@contain_query.close()
		@nids_query.close()
		@name_query.close()
		@type_query.close()
  end


	def get_wids()
		#returns the entire list of way ids from a database
		wids = Array.new()
		@wids_query.execute!(){|r| wids.push(r['wid'].to_i)}
		raise "No Ways found" if wids.empty?
		return wids
	end

	def wids_contain(nid)
		#nid is a node id, returns the list of ways that contain given nid
		wids = Array.new()
		@contain_query.execute!(nid){|r| wids.push(r[0].to_i)}
		return wids
	end


	def get_nids(wid)
		#wid is an integer 
		#returns an array of nids contained in the given wid
		nids = Array.new()
		@nids_query.execute!(wid){|r| nids.push(r[0].to_i)}
		@log.debug("Way #{wid} contains #{nids.length} nodes")
		raise "No nodes found" if nids.empty?
		return nids
	end

	def get_nodes(id)
		#id is an integer
		return get_nids(id)
	end
	
	def get_name(id)
		#id is an integer
		name = nil
		@name_query.execute!(id){|r| name = r[0]}
		#raise "No name found for #{id}" if name.nil?
		return name
	end

	def get_type(id)
		#id is an integer
		type = nil
		@type_query.execute!(id){|r| type = r[0]}
		#raise "No type found for #{id}" if type.nil?
		return type
	end

	def to_s()
		return @db.execute("SELECT DISTINCT name FROM ways;").flatten.inject(String.new()){|m,s| m + "#{s},"} 
	end
end

class Ways
	#A container class for the Way_sql and Way_buffer class
	#This class unifies the interface and checks the buffer before the sql. 
	def initialize (db,log)
		#db is a sql database object (properly SQLite3::Database.new(dbname), log is a logger object Logger.new(STDOUT)
		@way_sql = Way_SQL.new(db,log)
		@way_buffer = Way_Buffer.new(@way_sql.maxwid, log)
		@maxwid = @way_sql.maxwid
		@log = log
	end

  def close()
    @way_sql.close()
  end

	attr_reader :maxwid

	def add_new_wid(nodelist)
		#nodelist is an array of integer node ids. Adds a way to the list of known ways but creating a new buffer entry. Does NOT modify the Database.
		@way_buffer.add_new_wid(nodelist)
	end

	def add_mod_wid(nodelist,wid)
		#nodelist is an array of interger node ids. wid (an integer) is a known way id that is being modified. This added wid will "hide" the existing one since the buffer should be checked
		#first. Does NOT modify the Database.
		@way_buffer.add_mod_wid(nodelist,wid)
	end

	def get_wids()
		#here we don't care about the source, merely the existance so we're just looking for an any entry
		sql = @way_sql.get_wids()
		buffer = @way_buffer.get_wids()
		return (sql + buffer).uniq
	end

	def wids_contain(nid)
		#nid is an integer. here we don't care about the source, merely the existance so we're just looking for any entry
		buffer = @way_buffer.wids_contain(nid)
		sql = @way_sql.wids_contain(nid)
		return (sql + buffer).uniq
	end

	def get_nids(wid)
		#wid is an integer. here we want to give preference to bufferd values over sql values 
		tmp = @way_buffer.get_nids(wid)
		return tmp unless tmp.empty?
		return @way_sql.get_nids(wid)
	end

	def get_name(id)
		#id is a integer. if there was a name recorded for that id, return that (it shouldn't have changed). If not but the way was added return "unknown", otherwise return nil
		tmp = @way_sql.get_name(id)
		if tmp
			return tmp
		elsif @way_buffer.has_id?(id)
			return "unknown"
		else
			return nil
		end
	end

	def get_type(id)
		#id is an integer. if there was a type recorded for that id, return that (it shouldn't have changed). If not but the way was added return "ADD", other wise return nil.
		#the speed value will have to be interpolated from connecting ways. 
		tmp = @way_sql.get_type(id)
		if tmp
			return tmp
		elsif @way_buffer.has_id?(id)
			return "ADDED"
		else
			return nil
		end
	end

	def get_buffer_size()
		#returns the lenght of the buffer
		return @way_buffer.get_size()
	end

	def dump_buffer()
		#returns an array of wid/nid pairs
		return @way_buffer.dump_buffer().map{|x| [x[0],self.get_name(x[0]),self.get_type(x[0]),x[1]]}
	end

	def fill_buffer(tdb)
		#tdb is a sqllite object (SQLite3::Database.new), populates the buffer with values from the database
		tmp = Array.new()
		tdb.results_as_hash = true unless tdb.results_as_hash
		tdb.execute("SELECT * FROM gways"){|r| tmp.push([r['wid'].to_i,r['nid'].to_i])}
		@log.debug("Ways.fill_buffer: extracted\n#{tmp.map{|x| x.join(",")}.join("\n")}")
		wids = tmp.map{|x| x[0]}.uniq
		fill = wids.map{|x| [x,tmp.select{|y| y[0] == x}.map{|y| y[1]}]}
		@log.debug("Ways.fill_buffer: pushing\n#{fill.map{|x| x.join(",")}.join("\n")}")
		@way_buffer.fill_buffer(fill)
	end
end

if __FILE__ == $0
	begin
		#LOG instance static constant
		OPTIONS = Hash.new()
		LOG = Logger.new(STDOUT)
		$optparse = OptionParser.new do |opts|
			opts.banner = "Usage: Lib-NodeWay [OPTIONS]"
			opts.separator "Library or CLI:"
			opts.separator "Library: Front END for Sqlite3 map database. Provides Nodes and Ways Class which has seraching capabilities"
			opts.separator "(nodes nearest to a Specfic Lat/Lon pair, Ways containing a specific Node ID)."
			opts.separator "CLI:  For a given Map Database computes the center or uses specified point. Finds the nearest node and ways containing that node. A Map integrity check."

			OPTIONS[:lat] = nil
			opts.on('-x','--lat NUMBER',Float, 'Latitidue to search against (SINGLE SEARCH MODE)') do |lat|
			OPTIONS[:lat] = lat
			end

			OPTIONS[:lon] = nil
			opts.on('-y','--lon NUMBER',Float, 'Latitidue to search against(SINGLE SEARCH MODE)') do |lon|
				OPTIONS[:lon] = lon
			end

			#DEBUG level
			OPTIONS[:debug] = false
			opts.on('-d','--debug','Enable Debug messages (default: false)') do
				OPTIONS[:debug] = true
			end
		
			#DB to read from
			OPTIONS[:dbfile] = nil
			opts.on('-D','--dbfile FILE','PATH to READ databse file from') do |file|
				OPTIONS[:dbfile] = file
			end

			#DB to read from
			OPTIONS[:tdbfile] = nil
			opts.on('-T','--trace FILE','PATH to READ trace databse file from') do |file|
				OPTIONS[:tdbfile] = file
			end
	
			#help message
			opts.on( '-h', '--help', 'Display this screen' ) do
				puts opts
				exit
			end
		end
		$optparse.parse!

		#Instantiate the nodes and ways objects
		OPTIONS[:debug] ? LOG.level = Logger::DEBUG : LOG.level = Logger::INFO
		Tools.set_log(LOG)
		LOG.info("Main:Opening #{OPTIONS[:dbfile]}")
		db = SQLite3::Database.new(OPTIONS[:dbfile])
		nodes = Nodes.new(db,LOG)
		ways = Ways.new(db,LOG)
		unless OPTIONS[:tdbfile].nil?
			LOG.info("Main:Opening #{OPTIONS[:tdbfile]}")
			tdb = SQLite3::Database.new(OPTIONS[:tdbfile])
			nodes.fill_buffer(tdb) 
			ways.fill_buffer(tdb) 
		end

		new_node_1 = nodes.add_node(40.10,-71.023)
		new_node_2 = nodes.add_node(1.0,1.0)

		ways.add_new_wid([new_node_1,new_node_2])
		tmp_ways = ways.get_wids().first(4).map{|x| [x,ways.get_nids(x)]}
		tmp_ways[0][1].push(new_node_1)
		tmp_ways[1][1].unshift(new_node_1)
		tmp_ways[2][1].push(new_node_2)
		tmp_ways[3][1].unshift(new_node_2)
		tmp_ways.each{|x| ways.add_mod_wid(x[1],x[0])}

		LOG.info("Main:Map Bounding Box: #{nodes.minlat},#{nodes.minlon},#{nodes.maxlat},#{nodes.maxlon}")

		# Since we use a small box to constrain the size of the search space, this will crash if the node chosen is not in the map
		OPTIONS[:lat] ?  cenlat = OPTIONS[:lat] : cenlat = nodes.minlat + ((nodes.maxlat - nodes.minlat) / 2)
		OPTIONS[:lon] ?  cenlon = OPTIONS[:lon] : cenlon = nodes.minlon + ((nodes.maxlon - nodes.minlon) / 2)

		OPTIONS[:lat] && OPTIONS[:lon] ? LOG.info("Chosen point @ #{cenlat},#{cenlon}") : LOG.info("Center @ #{cenlat},#{cenlon}")

		nearest = nil
		wids = nil

		# The nearest node that contains a way. This is above the context of nodes and ways so it should properly be done in code that lives above them 
		nodes.get_nearest_arr(cenlat,cenlon).each{|n|
			nearest = n[0]
			wids = ways.wids_contain(n[0])
			break unless wids.empty?
		}
		
		
		LOG.info("Main:Test results:")
		LOG.info("Main:Nearest to center #{nearest} @ #{nodes.get_lat(nearest)},#{nodes.get_lon(nearest)}")
		LOG.info("Main:Containing Wids: There are #{wids.length} wids, they are")
		wids.each{|x| LOG.info("#{x} #{ways.get_name(x)}")}
		LOG.info("Main:Node Buffer has #{nodes.get_buffer_size()} nodes")
		LOG.info("Main:Node Buffer's contents are\n#{nodes.dump_buffer.map{|x| x.join(",")}.join("\n")}")
		buff_nearest = nodes.get_nearest_arr(40.0,-70.0).first[0]
		LOG.info("Main:Cloest to 40,-71 is #{buff_nearest} which is at #{nodes.get_lat(buff_nearest)},#{nodes.get_lon(buff_nearest)}")
		LOG.info("Main:Way Buffer has #{ways.get_buffer_size()} ways")
		LOG.info("Main:Ways Buffer's contents are\n#{ways.dump_buffer.map{|x| x.join(",")}.join("\n")}")
		LOG.info("#{ways.wids_contain(new_node_1).join(",")} ways contain #{new_node_1}")
		way_contain = ways.wids_contain(new_node_1).first
		LOG.info("#{ways.get_nids(way_contain).join(",")} are the nodes in #{way_contain}")
	ensure
    nodes.close
    ways.close
		LOG.close
	end
end

