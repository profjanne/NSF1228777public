#!/usr/bin/ruby
#This tool will download a map specfied via the specfied cli arguments. It will then stich this map togheter into an sqlite database

#threading
require 'net/http'
require 'net/https'

require 'rubygems'

require 'thread'

#my library
require './lib-Dist'

#rest API interface
require 'rest_client'

#singleton mixin
require 'singleton'

#logging
require 'logger'

#option parsing
require 'optparse'

#sqlite
require 'sqlite3'

class WebGetFailed < RuntimeError
end

class XMLRegxpFailed < RuntimeError
end

class WebData
	include Singleton
	#a container class that queries the web for data as needed. 
	
	
	def initialize ()
		@minlat = nil
		@minlon = nil
		@maxlat = nil
		@maxlon = nil
		@nodes = nil
		@ways = nil
		@chunk_size  = nil
		@log = nil
	end

	attr_reader :nodes, :ways, :minlat, :minlon, :maxlat, :maxlon

	
	def set_params(log,size)
		#adjust chunk size for speed vs node count
		@chunk_size = size
		@log = log
		@log.debug("Internal Params set, #{@chunk_size} = size")
	end

	def update (minlat,minlon,maxlat,maxlon)
		#threaded updated

		#dont need to update if map boundaries are already set
		return true if [minlat,minlon,maxlat,maxlon].zip([@minlat,@minlon,@maxlat,@maxlon]).inject(false){|m,s| s[0]==s[1] ? m = true : m = false}

		@log.warn("Updating Webdata")
		@minlat = minlat
		@minlon = minlon
		@maxlat = maxlat
		@maxlon = maxlon
		
		#New internal storage structures (dumping the old ones by dropping context)
		@nodes=Array.new()
		@ways=Array.new()


		#get chunks
		chunks = get_chunks(minlat,minlon,maxlat,maxlon)
		raise "Too few chunks per thread" if OPTIONS[:threads] > chunks.length 
		
		#chop them up into separate arrays so that each thread can work on them
		@log.debug("Total number of chunks #{chunks.length}")
		
		#create a attempt count
		chunks.map!{|x| [x,0]}

		#threading is required now (at least 2) but this is reasonable since there will probably always be more than 1 chunk per map.
		raise "Too few threads" if OPTIONS[:threads] < 2

		#mutex for threads
		lock = Mutex.new()

		#global failure counter, as request fail this gets incremented. Each thread (except 0) will check this counter
		#if it's higer than the ammount of failures they new about when they started then a bad condition is occuring and they should goto sleep
		fails = 0

		threads = (0..OPTIONS[:threads]-1).to_a.map{ |i|
			Thread.new {
				@log.debug("Thread #{i} starting")
				myfails = 0
				until chunks.empty? do 
					#perpetually go to sleep until the number of failures I knew about is more than the global number of failures
					time = 0
					lock.synchronize {
						#all external resource checks need to be synchronised
						if fails >  myfails and i != 0
							#if I'm not the first thread and the number of failures is getting bigger than what I previously knew about
							#goto sleep
							time = 5 + rand(5)
							@log.warn("Thread #{i}: fails #{fails} is greater than myfails #{myfails}")
						end
					}
					if time != 0
						#time is basically my goto sleep flag, the result of the synchronised badness check
						@log.warn("Thread #{i} sleeping #{time}")
						sleep(time)
						next
					end

					#grab a chunk and set the number of failures I know about, this is the "beginning of processing"
					curchunk = nil
					lock.synchronize{myfails = fails; curchunk = chunks.pop()}

					@log.debug("Thread #{i}: attempt #{curchunk[1]}: myfails #{myfails}: working on #{curchunk[0][0]},#{curchunk[0][1]},#{curchunk[0][2]},#{curchunk[0][3]}")
					begin
						#if the chunk failure counter > 5, It's bad and the map is incomplete so give up
            
						if curchunk[1] > 5
							@log.fatal("thread #{i}: #{curchunk[0][0]},#{curchunk[0][1]},#{curchunk[0][2]},#{curchunk[0][3]} failed too many times. Giving up")
							abort
						end

						#attempt to grab the nodes and ways from the web
						nodes = nil
						ways = nil
            #Download the map data and parse nodes and ways
						webres=query(curchunk[0][0],curchunk[0][1],curchunk[0][2],curchunk[0][3])
						nodes = get_nodes(webres)
						ways = get_ways(webres)

						#store the results if sucessfull and decremnet the failure count
						@log.debug("thread #{i} merges #{nodes.length} nodes and #{ways.length} ways")
						lock.synchronize {
							nodes.each{|x| @nodes.push(x)}
							ways.each{|x| @ways.push(x)}
							fails -= 1 unless fails == 0
						}
					rescue => e
						#If a particular set failed, increment it's failure counter, and push it on the bottom of the stack
						@log.warn("thread #{i}: Failures #{fails}:\n Problem processing XML, pushing #{curchunk[0][0]},#{curchunk[0][1]},#{curchunk[0][2]},#{curchunk[0][3]} back,\n ERROR:#{e.message}")
						lock.synchronize{fails += 1; curchunk[1] += 1; chunks.unshift(curchunk)} 
					end
				end
				@log.debug("thread #{i} completed")
			}
		}
		threads.map{|t| t.join}
		@nodes.uniq!
		@ways.uniq!
		return true
	end

	def get_ways(xml)
		#xml is an xmldoc instance
		#extracts the nodes from the xmldoc
		ways_str = xml.scan(/(<way.*?way>)/m)
		#I use a flatten because the previous result was an array of arrays
		ways = ways_str.flatten.map{|x|
			id = x.scan(/way\s*id=\"(\d*)\"/m)
			nodes =  x.scan(/ref=\"(\d*)\"/m)
			nodes.map!{|node| node.first.to_i}
			type = x.scan(/k="highway"\s*v=\"(.*?)\"/m)
      #Okay, things with highway=construction may have their type under
      #the construction key
      if (not type.empty? and type[0][0] == "construction")
        type = x.scan(/k="construction"\s*v=\"(.*?)\"/m)
      end
			type = [["NotHighWay"]] if type.empty?
			name = x.scan(/k="name"\s*v=\"(.*?)\"/m)
			name = "unknown" if name.empty?
      #Give names to some types of roads
      if ("unknown" == name)
        if (type[0][0] == "service")
          name = "service"
        elsif (type[0][0] =~ /.*_link/)
          name = "link"
        elsif (type[0][0] =~ /.*_junction/)
          name = "junction"
        end
      end
      #If the road is one-way then the ordering of the nodes is
      #important and denotes node to node connectivity.
     
			wayness = x.scan(/k="oneway"\s*v=\"(.*?)\"/m)
			wayness = "no" if wayness.empty?
      #-1 means that the nodes are not in order
      if (wayness[0] == "-1")
        nodes = nodes.reverse
      end
      #Check the note
      note = x.scan(/k="note"\s*v=\"(.*?)\"/m)
      #If there is a note labelling this way as being two-way later then fix it
      if (nil != note and note == "will be two-way")
        wayness = "no"
      end
      #Get the number of lanes for turning distance information.
      #The number of lanes is similar to oneway -- one way roads are often
      #unlabelled.
      lanes = x.scan(/k="lanes"\s*v=\"(.*?)\"/m)
      if (lanes.empty?)
        lanes = 1
      end
			[id.flatten.first.to_i,name,type,wayness,lanes,nodes]
		}
		raise XMLRegxpFailed, "No ways found",caller if ways.empty?
		@log.debug("found #{ways.length} ways, the first one is #{ways.first[0]},#{ways.first[1]},#{ways.first[2]}")
		return ways
	end

	def get_nodes(xml)
		#xml is an xmldoc instance
		#extracs the nodes from the xmldoc
		nodes_str = xml.scan(/(<node.*?>)/m)
		nodes = Array.new()
		nodes_str.flatten.map{|x| x.scan(/id=\"(\d*)\".*?lat=\"(-?\d*.\d*)\".*?lon=\"(-?\d*.\d*)\"/m)}.each{|x| x.each { |y| nodes.push([y[0].to_i, y[1].to_f, y[2].to_f])}}
		raise XMLRegxpFailed, "No nodes found", caller if nodes.empty?
		@log.debug("found #{nodes.length} nodes, the first one is #{nodes.first}")
		return nodes
	end

	def get_chunks(minlat,minlon,maxlat,maxlon)

		#returns an array of 4 coords that is the large box chopped into @chunk_size mile diagonal boxes
		#Emprical test suggest 3 mile blocks seem to work ok, we will have to make a sloppy aproximation
		
		x1 = minlat
		y1 = minlon
		x2 = maxlat
		y2 = maxlon
		chunks = Array.new()

		#if diagonal distance is less than @chunk_size nothing to do
		if Tools.latlondist(x1,y1,x2,y2) < @chunk_size then  chunks.push([x1,y1,x2,y2]); return chunks end

		delx = (x1 - x2).abs
		dely = (y1 - y2).abs
	
		#cumpute the factor brute force	
		factor  = 2;	
		cdist = Tools.latlondist(x1,y1,x2,y2)
		while cdist > @chunk_size
			xnew = x1 + delx / factor
			ynew = y1 + dely / factor
			factor += 1
			cdist = Tools.latlondist(x1,y1,xnew,ynew)
		end

		factor += 1
		@log.info("Factor was determined #{factor}")

		#assembly the arrays
		res = Array.new()
		xoff = delx / factor
		yoff = delx / factor
		xtw = xoff / 2
		ytw = xoff / 2
		xbot = x1
		ybot = y1

		while xbot < x2 + xoff + xtw
			while ybot < y2 + yoff + ytw
				#make it a little bigger so they overlap
				res.push([xbot - xtw, ybot - ytw, xbot + xoff + xtw, ybot + yoff + ytw])
				ybot += yoff
			end
			ybot = y1
			xbot += xoff
		end

		
		return res
	end

	def round_float(num, pre = 6)
		#arbitrary precision float round
		return (num * (10.0 ** pre)).round / (10.0 ** pre)
	end


	def query(minlat,minlon,maxlat,maxlon)
		#use the restclient to pull a partial map, the distance for the box size should be than 1 mile across
	
#		old api strings, The mapquest one is the least restrictive about large sets of down load queries
#		api_str = "http://api.openstreetmap.org/api/0.6/map?bbox="
#		api_str = "http://www.informationfreeway.org/api/0.6/map?bbox="
		#This is another format that works for OSM, seem to allow arbitrary sizes
    #http://open.mapquestapi.com/xapi/api/0.6/*[bbox=-74.4893,40.4237,-74.4359,40.4771]
		api_str = "http://open.mapquestapi.com/xapi/api/0.6/map?bbox="
   

		#precision of round
		
		pre = 5

#		the request URL as a strange ordering #{minlon},#{minlat},#{maxlon},#{maxlat}
		param_str="#{round_float(minlon,pre)},#{round_float(minlat,pre)},#{round_float(maxlon,pre)},#{round_float(maxlat,pre)}"
		@log.info("Asking the web for #{param_str}")
		begin
			res = RestClient.get(api_str + param_str)
			return res.to_s
		rescue => e
			@log.warn("Rest Client exception caught for #{minlat},#{minlon};#{maxlat},#{maxlon} ERROR: #{e.message}")
			raise
		end
	end
	
	def to_osm(fname)
		begin
		#build the xml file by hand (infinitely faster than useing the library)
		file = File.new(fname,"w")
		@log.info("Writing OSM to file #{fname}")
		file.puts("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
		file.puts("<osm version=\"0.6\">")
		file.puts(" <bounds minlat=\"#{@minlat}\" minlon=\"#{@minlon}\" maxlat=\"#{@maxlat}\" maxlon=\"#{@maxlon}\"/>")
		
		@nodes.each{|x| file.puts(" <node id=\"#{x[0]}\" lat=\"#{x[1]}\" lon=\"#{x[2]}\">\n  <tag />\n </node>")}
		@ways.each{|x|
			file.puts(" <way id=\"#{x[0]}\">")
			file.puts("  <tag k=\"name\" v=\"#{x[1]}\"/>")
			file.puts("  <tag k=\"highway\" v=\"#{x[2]}\"/>")
			x[3..-1].each{|nd| file.puts("  <nd ref=\"#{nd}\"/>")}
			file.puts(" </way>")
		}
		file.puts("</osm>")
		ensure
		file.close
		end
	end

	def to_txt(fname)
		#debug txt file method
		begin
		@log.info("Writing Txt File to #{fname}")
		file = File.new(fname,"w")
		@nodes.each{|x| file.puts x[0]}
		file.puts "###############################################################"
		@ways.each{|x| file.puts x[0]}
		ensure
		file.close
		end
	end

	def to_sql(fname)
		#makes an index sql db
		db = SQLite3::Database.new(fname)
		db.type_translation = true
		@log.info("Writing sql db to #{fname}")
		db.execute("PRAGMA synchronous=OFF;")
		db.execute("PRAGMA cache_size = 10000;")
		db.execute("PRAGMA journal_mode = WAL;")


    #The node index is a magic constant in the @ways variable.
    #Each value before that index hold just 1 item, all items from
    #this index onwards are node ids
    node_idx = 5
		
		#add ways to DB
		if db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='ways';").empty?
			@log.warn("Making a new WAYS table")
			db.execute("CREATE TABLE 'ways' ('wid' NUMBER, 'name' VARCHAR(50), 'type' VARCHAR(50), 'nid' NUMBER);")
			db.execute("create index wid_nid ON ways (wid,nid);")
		end
		db.execute("BEGIN;")
		@ways.each {|way|
			wid  = way[0]
			name = way[1]
			type = way[2]
			way[node_idx].each{|nid| db.execute("INSERT or REPLACE INTO 'ways' (wid, name, type, nid) values (?,?,?,?);",*[wid,name,type,nid]){|r| @log.debug(r)}}
		}
		db.execute("COMMIT;")

    #Add adjacencies into the DB for one way roads.
		if db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='adjacencies';").empty?
			@log.warn("Making a new adjacencies table")
			db.execute("CREATE TABLE 'adjacencies' ('wid' NUMBER, 'from_nid' NUMBER, 'to_nid' NUMBER);")
      db.execute("create index fromnid_wid ON adjacencies (from_nid,wid);")
		end
    #Also store the number of lanes for each way
		if db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='lanes';").empty?
			@log.warn("Making a new lanes table")
			db.execute("CREATE TABLE 'lanes' ('wid' INTEGER PRIMARY KEY, 'lanes' NUMBER);")
		end


		db.execute("BEGIN;")
		@ways.each {|way|
			wid     = way[0]
      lanes   = way[4]
      #First store the number of lanes
      db.execute("INSERT or REPLACE INTO 'lanes' (wid, lanes) values (?,?);", wid, lanes){|r|
        @log.debug(r)}
    }
		db.execute("COMMIT;")

		db.execute("BEGIN;")
		@ways.each {|way|
			wid     = way[0]
			name    = way[1]
			type    = way[2]
      wayness = way[3]

      #If this is not a bidirectional road then insert each pair of nodes
      #as adjacent
      if ("no" != wayness) then
        way[node_idx][1..-1].zip(way[node_idx]).each{|pair| db.execute("INSERT or REPLACE INTO 'adjacencies' (wid, from_nid, to_nid) values (?,?,?);",*[wid,pair[1], pair[0]]){|r| @log.debug(r)}}
      else
        #For the bidirectional road just insert them both in each direction
        way[node_idx][1..-1].zip(way[node_idx]).each{|pair| db.execute("INSERT or REPLACE INTO 'adjacencies' (wid, from_nid, to_nid) values (?,?,?);",*[wid,pair[0], pair[1]]){|r| @log.debug(r)}}
        way[node_idx][1..-1].zip(way[node_idx]).each{|pair| db.execute("INSERT or REPLACE INTO 'adjacencies' (wid, from_nid, to_nid) values (?,?,?);",*[wid,pair[1], pair[0]]){|r| @log.debug(r)}}
      end
		}
		db.execute("COMMIT;")

		#add nodes to DB
		db.execute("BEGIN;")
		if db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='nodes';").empty?
			@log.warn("Making a new NODES table")
			db.execute("CREATE TABLE 'nodes' ('id' NUMBER PRIMARY KEY, 'latitude' NUMBER, 'longitude' NUMBER);")
			db.execute("create index lat_lon ON nodes (latitude, longitude);")
		end
		@nodes.each {|node| db.execute("INSERT or REPLACE into 'nodes' (id, latitude, longitude) values (?,?,?);",*node){|r| @log.debug(r)}}
		db.execute("COMMIT;")

		#add mapping form road type to speed limits into the DB
		roadclasses = [
			["NotHighWay",-1,-1],
			["unknown",0,0],
			["motorway",55,65],
			["motorway_junction",55,65],
			["motorway_link",25,35],
			["trunk",45,55],
			["trunk_link",25,35],
			["primary",40,50],
			["primary_link",25,35],
			["secondary",35,45],
			["secondary_link",25,35],
			["tertiary",30,40],
			["tertiary_link",25,25],
			["residential",25,25],
			["service",5,25],
			["construction",25,45]
		]
		db.execute("BEGIN;")
		if db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='speedtype';").empty?
			@log.warn("Making a new SpeedType table")
			db.execute("CREATE TABLE 'speedtype' ('type' VARCHAR(50) PRIMARY KEY, 'minspd' NUMBER, 'maxspd' NUMBER);")
		end
		roadclasses.each {|spdar| db.execute("INSERT or REPLACE into 'speedtype' (type, minspd, maxspd) values (?,?,?);",*spdar){|r| @log.debug(r)}}
		db.execute("COMMIT;")

		#add latitude and longitude bounds into the DB
		db.execute("BEGIN;")
		if db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='bounds';").empty?
			@log.warn("Making a new BOUNDS table")
			db.execute("CREATE TABLE 'bounds' ('name' VARCHAR(50), 'latitude' NUMBER, 'longitude' NUMBER);")
		end
		db.execute("INSERT or REPLACE into 'bounds' (name, latitude, longitude) values (?,?,?);","min",@minlat,@minlon){|r| @log.debug(r)}
		db.execute("INSERT or REPLACE into 'bounds' (name, latitude, longitude) values (?,?,?);","max",@maxlat,@maxlon){|r| @log.debug(r)}
		db.execute("COMMIT;")

		db.close()
	end

	def to_mar(fname)
		#marshall dump
		File.open(fname,"wb"){|file| Marshal.dump([@nodes,@ways,@minlat,@maxlat,@minlon,@maxlon],file)}
	end
end


if __FILE__ == $0
	begin
	#LOG instance static constant
		OPTIONS = Hash.new()
		LOG = Logger.new(STDOUT)
		$optparse = OptionParser.new do |opts|

			opts.banner = "Usage: get_map [OPTIONS]"
			opts.separator ""
			opts.separator "Given 2 pairs of Lat/Lon, will chop the square map up into chunks of fixed width. get_map will the download each chunk seprately and reassemble"
			opts.separator "the chunks into one large collection of Nodes and Ways. Possible Out put types are OSM(XML), Database(Sqlite), Text, or Marshall file"

			#DEBUG level
			OPTIONS[:debug] = false
			opts.on('-d','--debug','Enable Debug messages (default: false)') do
				OPTIONS[:debug] = true
			end

			#minlat
			OPTIONS[:minlat] = "40.3718000".to_f
			opts.on('-x','--minlat MINLAT','(Default = 40.3718000) Minimum Latitude') do |minlat|
				OPTIONS[:minlat] = minlat.to_f
			end

			#minlon
			OPTIONS[:minlon] = "-74.5975000".to_f
			opts.on('-y','--minlon MINLON','(Default = -74.5975000) Minimum Longitude') do |minlon|
				OPTIONS[:minlon] = minlon.to_f
			end

			#maxlat
			OPTIONS[:maxlat] = "40.4695000" .to_f
			opts.on('-X','--maxlat MAXLAT','(Default = 40.4695000) Maximum Latitude') do |maxlat|
				OPTIONS[:maxlat] = maxlat.to_f
			end

			#maxlon
			OPTIONS[:maxlon] = "-74.4465000".to_f
			opts.on('-Y','--maxlon MAXLON','(Default = -74.4465000) Maximum Latitude') do |maxlon|
				OPTIONS[:maxlon] = maxlon.to_f
			end

			#OSM file name
			OPTIONS[:osmfile] = nil
			opts.on('-O','--osmfile FILE','PATH to output OSM file (in xml), if not specified, this will  not be output') do |file|
				OPTIONS[:osmfile] = file
			end

			#DB file name
			OPTIONS[:dbfile] = nil
			opts.on('-D','--dbfile FILE','PATH to output sqlite3 db, if not specified will  not be output') do |file|
				OPTIONS[:dbfile] = file
			end

			#mar file name
			OPTIONS[:marfile] = nil
			opts.on('-M','--marfile FILE','PATH to output binary store, if not specified will  not be output') do |file|
				OPTIONS[:marfile] = file
			end

			#mar file name
			OPTIONS[:txtfile] = nil
			opts.on('-T','--txtfile FILE','PATH to output text file of node ids for debugging, if not specified will  not be output') do |file|
				OPTIONS[:txtfile] = file
			end

			#thread count
			OPTIONS[:threads] = 2
			opts.on('-t','--threads NUMBER','Number of threads, default 2') do |threads|
				OPTIONS[:threads] = threads.to_i
			end
	
			#Chunk size
			OPTIONS[:chunk] = 5
			opts.on('-c','--chunk NUMBER','Size of chunks defualt = 5') do |chunk|
				OPTIONS[:chunk] = chunk.to_i
			end

			#help message
			opts.on( '-h', '--help', 'Display this screen' ) do
				puts opts
				exit
			end
		end
		$optparse.parse!
		OPTIONS[:debug] ? LOG.level = Logger::DEBUG : LOG.level = Logger::INFO
		LOG.debug("specfied options:\n#{OPTIONS.keys.inject(String.new()){|m,c| m + "key:#{c} value:#{OPTIONS.values_at(c)} \n"}}")
		Tools.set_log(LOG)
		
		#bounding box check 
		bbox = [OPTIONS[:minlat],OPTIONS[:minlon],OPTIONS[:maxlat],OPTIONS[:maxlon]]
		raise "Minlat should be smaller than Maxlat" if bbox[2] <= bbox[0]
		raise "Minlon should be smaller than Maxlon" if bbox[3] <= bbox[1] 
		webdata = WebData.instance()
		webdata.set_params(LOG,OPTIONS[:chunk])
		webdata.update(bbox[0],bbox[1],bbox[2],bbox[3])

		LOG.info("Number of ways #{webdata.ways.length}")
		LOG.info("Number of Nodes #{webdata.nodes.length}")

		webdata.to_osm(OPTIONS[:osmfile]) if OPTIONS[:osmfile]
		webdata.to_sql(OPTIONS[:dbfile]) if OPTIONS[:dbfile]
		webdata.to_mar(OPTIONS[:marfile]) if OPTIONS[:marfile]
		webdata.to_txt(OPTIONS[:txtfile]) if OPTIONS[:txtfile]
	rescue  => e
		LOG.fatal("Main block failed #{e.message}")
		abort
	ensure
		LOG.close
	end
end
