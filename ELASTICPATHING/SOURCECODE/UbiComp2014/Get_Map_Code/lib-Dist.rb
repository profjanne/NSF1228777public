#!/usr/bin/ruby
#Tools for dealing with GPS traces. Computes speeds as Distance / time from a given gps file. 
#Run as a standalone spits out speed data calculated from gps

require 'date'
require 'logger'
require 'optparse'
require 'gsl'

class TooFewSplinePoints < StandardError
end

class IndexMisMatch < StandardError
end

class TooManyIntersections < StandardError
end

class CantConnect < StandardError
end

class AleadyConnected < StandardError
	attr :inter
	def initialize(inter)
		@inter = inter
	end
end

#Radius of the Earth
ROE=6371

class Spline
	def initialize(dependant, independant,log)
		#dependant is an array of floats of the dependant variable
		#independant is an array of floats of the independant variable
		#the independant variable array is assumed to be ordered lowest to highest.
		@log = log

		#sanity checks
		#Dropped the unique requirement on dependant, as it doesn't have to be
		raise TooFewSplinePoints, "Spline.new: Need at least 3 sets of coords to build a spline (Not enough independant vars)" if independant.uniq.length < 3
		raise IndexMisMatch, "Spline.new: Must have equal numbers of dependant and independant variables" if dependant.length != independant.length

		#bounds
		@x_max = independant.last
		@x_min = independant.first
		@y_max = dependant.max
		@y_min = dependant.min

		#index ordering check
		raise IndexMisMatch, "independant varibles must be ordered monotoically increaing" if @x_max < @x_min

		#build the spline
		@log.debug("Reticulating Splines")
		y = GSL::Vector.alloc(dependant)
		x = GSL::Vector.alloc(independant)
		@spline = GSL::Spline.alloc(x,y)
	end

	attr_reader :x_max, :x_min, :y_max, :y_min

	def eval_arr(points)
		#points is an integer, returns an array of interpolated [x,y] pairs
		scale = (@x_max - @x_min) / points.to_f
		return (0..points).map{|i| index = @x_min + (scale * i); [@spline.eval(index), index]}
	end
	
	def deriv_arr(points)
		#points is an integer, returns an array of interpolated [x,y] pairs
		scale = (@x_max - @x_min) / points.to_f
		return (0..points).map{|i| index = @x_min + (scale * i); [@spline.eval_deriv(index), index]}
	end

	def deriv2_arr(points)
		#points is an integer, returns an array of interpolated [x,y] pairs
		scale = (@x_max - @x_min) / points.to_f
		return (0..points).map{|i| index = @x_min + (scale * i); [@spline.eval_deriv2(index), index]}
	end

	def eval_point(point)
		#point is a single value of the independant variable that we need
		return @spline.eval(point)
	end

	def deriv_point(point)
		#point is a single value of the independant variable that we need
		return @spline.deriv(point)
	end

	def deriv2_point(point)
		#point is a single value of the independant variable that we need
		return @spline.deriv2(point)
	end

	def find(dep_val)
		#dep_val is a float, the value of the dependant variable you want to reverseresolve to the independant variable
		return @spline.find(dep_val)
	end

end

class LatLonSpline
	#A container for the two splies that make up a lat/lon function. Can calculate individual points on the spline, or fill in the points between a range
	def initialize(coords,log)
		@log = log
		#coords an array of float 3 tuples, lat/lon/index
		@log.debug("LatLonSpline.initialize: Building a spline between:\n#{coords.first.join(",")}\n#{coords.last.join(",")}")
		lats = coords.map{|arr| arr[0]}
		lons = coords.map{|arr| arr[1]}
		time = coords.map{|arr| arr[2]}
		raise ("LatLonSpline: No independant Vairable specfied") if time.first.nil?

		@lat_spline = Spline.new(lats,time,@log)
		@lon_spline = Spline.new(lons,time,@log)
	end

	def interpolate(points)
		#points is an integer that is the number of points you want to fill in between the first and last index
		#
		#Since latitude and longitude are not functionally realted to each other, it does not make sense to interpolate with either being the independant
		#variable. Instead we will build two seperate functions and draw a paramentric curve. Thus the lat/lon pairs must be evaluated against values 
		#of t. That is given a t, we will return (x(t),y(t),x'(t),y'(t),x''(t),y''(t)). We may have to revisit this later to return dy/dx
		
		lat_interp = @lat_spline.eval_arr(points)
		lon_interp = @lon_spline.eval_arr(points)
		return (0..lat_interp.length-1).map{|i| [lat_interp[i][0],lon_interp[i][0],lat_interp[i][1]]}
	end

	def deriv_interp(points)
		#points is an integer that is the number of points you want to fill in between the first and last index
		#returns the derivative between said indicies
		
		lat_interp = @lat_spline.deriv_arr(points)
		lon_interp = @lon_spline.deriv_arr(points)
		return (0..lat_interp.length-1).map{|i| [lat_interp[i][0],lon_interp[i][0],lat_interp[i][1]]}
	end

	def deriv2_interp(points)
		#points is an integer that is the number of points you want to fill in between the first and last index
		#returns the derivative between said indicies
		
		lat_interp = @lat_spline.deriv2_arr(points)
		lon_interp = @lon_spline.deriv2_arr(points)
		return (0..lat_interp.length-1).map{|i| [lat_interp[i][0],lon_interp[i][0],lat_interp[i][1]]}
	end

	def eval_point(index)
		#index is a float, returns the interploated value at index as a 2 tuple
		return [@lat_spline.eval_point(index),@lon_spline.eval_point(index)]
	end

	def deriv_point(index)
		#index is a float, returns the derative of interploated value at index as a 2 tuple
		return [@lat_spline.deriv_point(index),@lon_spline.deriv_point(index)]
	end

	def deriv2_point(index)
		#index is a float, returns the 2nd deratvive interploated value at index as a 2 tuple
		return [@lat_spline.deriv2_point(index),@lon_spline.deriv2_point(index)]
	end

	def find(lat,lon)
		#lat/lon are floats, the average of what the find fuction returns will be what we delcare is the independant varable.
		lat_ind = @lat_spline.find(lat)
		lon_ind = @lon_spline.find(lon)
		return (lat_ind + lon_ind)/2.0
	end
end


class LatLonLine
	#A 2 point interpolation class. The interface is designed to mimic that of spline.
	def initialize(coords,log)
		@log = log
		@coords = coords
		raise ("LatLonLine.new: No independant Vairable specfied") if @coords.first[2].nil?

		@min_ind = @coords.each_with_index.min{|x,y| x[0][2] <=> y[0][2]}[1]
		@max_ind = @coords.each_with_index.max{|x,y| x[0][2] <=> y[0][2]}[1]
		@log.debug("LatLonLine.new: Building a LINE between\n#{@coords[@min_ind].join(",")}\n#{@coords[@max_ind].join(",")}")
	end

	def interpolate(points)
		#array of interpolated points
		scale = (@coords[@max_ind][2] - @coords[@min_ind][2]) / points.to_f
		return (0..points).map{|i| index = scale * i; coords = eval_point(index); [coords[0],coords[1],index]}
	end

	def deriv_interp(points)
		#array of constants
		scale = (@coords[@max_ind][2] - @coords[@min_ind][2]) / points.to_f
		return (0..points).map{|i| index = scale * i; coords = deriv_point(index); [coords[0],coords[1],index]}
	end

	def deriv2_interp(points)
		#array of zeros
		scale = (@coords[@max_ind][2] - @coords[@min_ind][2]) / points.to_f
		return (0..points).map{|i|  index = scale * i; [0,0,index]}
	end

	def eval_point(index)
		#index is an integer, this is an equation fo the for y_1(1-t) + y_2(t) where t goes from (0 to 1)
		slope = deriv_point(index)
		return [@coords[@min_ind][0] + index * slope[0], @coords[@min_ind][1] + index * slope[1]]
	end

	def deriv_point(index)
		#linear 1st derivative = slope (constant)
		lat_diff = (@coords[@max_ind][0] - @coords[@min_ind][0])
		lon_diff = (@coords[@max_ind][1] - @coords[@min_ind][1])
		time_diff = (@coords[@max_ind][2] - @coords[@min_ind][2])
		return [lat_diff/time_diff, lon_diff/time_diff]
	end

	def deriv2_point(index)
		#linear 2nd derative = 0
		return [0,0]
	end

	def find(lat,lon)
		
		raise "LatLonLine.find: Not used and not implemented yet"
	end
end

class Tools
	def initialize()
		raise "Don't instantiate Tools"
	end

	def self.set_log(log)
		@log=log
		@log.debug("lib-Dist: Log initalized")
	end

	def self.latlondist(lat1,lon1,lat2,lon2)
		#Uses the haversine formula to convert to distance in Miles
	
		#Convert Degrees to Radians
		dlat = (lat2 - lat1)* (Math::PI / 180)
		dlon = (lon2 - lon1)* (Math::PI / 180)
		rlat1 = lat1 * (Math::PI / 180)
		rlat2 = lat2 * (Math::PI / 180)
		
		#haversine formula http://www.movable-type.co.uk/scripts/latlong.html
		a = (Math.sin(dlat / 2) ** 2) + ((Math.sin(dlon/2) ** 2) * Math.cos(rlat1) * Math.cos(rlat2))
		c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a))
		return ROE*c*0.621371192
	end	

	def self.interpolate(coords, points)
		#coords is an array of 3 tuples of lat/lon/index, and points is an interger,it is number of interpolated points to split the index interval (time, or something else)
		if coords.length == 2
			return LatLonLine.new(coords,@log).interpolate(points)
		elsif coords.length > 2
			return LatLonSpline.new(coords,@log).interpolate(points)
		else
			raise "Tools.interpolate: Can't interpolate with less than 2 points"
		end
	end

	def self.line_intersect(int_points)
		#points is an Array of 2 tuples, lat/lon pairs. The first two should be colinear on line A, and the second on line B.
		#returns the linersection point between these points if it exitists
		
		#Add some context to the point names
		pA1,pA2,pB1,pB2 = int_points
	
		#calculate the intersection point (this should never fail since the linear aproximations should intersect somwhere, they likely hood of parrellel lines is low)	
		denom = (GSL::Matrix[[pA1[0]-pA2[0],pA1[1]-pA2[1]],[pB1[0]-pB2[0],pB1[1]-pB2[1]]]).det
		m_A1_A2 = (GSL::Matrix[[pA1[0],pA1[1]],[pA2[0],pA2[1]]]).det
		m_B1_B2 = (GSL::Matrix[[pB1[0],pB1[1]],[pB2[0],pB2[1]]]).det
		x = (GSL::Matrix[[m_A1_A2,pA1[0]-pA2[0]],[m_B1_B2,pB1[0]-pB2[0]]]).det / denom
		y = (GSL::Matrix[[m_A1_A2,pA1[1]-pA2[1]],[m_B1_B2,pB1[1]-pB2[1]]]).det / denom

		#however the intersection may be not be between the points, if that is the case we delcare no intersection.
		if pA1[0] < pA2[0]
			return nil if x < pA1[0] or x > pA2[0]
		else
			return nil if x >  pA1[0] or x < pA2[0]
		end
		if pB1[0] < pB2[0]
			return nil if x < pB1[0] or x > pB2[0]
		else
			return nil if x >  pB1[0] or x < pB2[0]
		end
		if pA1[1] < pA2[1]
			return nil if y < pA1[1] or y > pA2[1]
		else
			return nil if y >  pA1[1] or y < pA2[1]
		end
		if pB1[1] < pB2[1]
			return nil if y < pB1[1] or y > pB2[1]
		else
			return nil if y > pB1[1] or y < pB2[1]
		end
		#if it all passes then we return x,y
		@log.debug("Tools.Line_intersect: Intersection found between :\n#{pA1.join(",")}\n#{pA2.join(",")}\n#{pB1.join(",")}\n#{pB2.join(",")}\nat\n#{x},#{y}")
		return [x,y]
	end

	def self.refine(ref1, ref2, threshold, points)
		#ref1 and ref2 are two sets of two tuples (3 points each). refine will interpolate between the 3 points and return the cloest point and its immedate interpolated neighbors

		@log.debug("Tools.refine: refining points between \n#{ref1.map{|x| x.join(",")}.join("\n")}\nand\n#{ref2.map{|x| x.join(",")}.join("\n")}")

		#order the points if they are not already ordered
		ref1_ordered = self.order_curve(ref1)
		ref2_ordered = self.order_curve(ref2)

		#prime the distance variables
		ref1_ordered_width = self.latlondist(ref1_ordered.first[0],ref1_ordered.first[1],ref1_ordered.last[0],ref1_ordered.last[1])
		ref2_ordered_width = self.latlondist(ref2_ordered.first[0],ref2_ordered.first[1],ref2_ordered.last[0],ref2_ordered.last[1])

		#until we've zoomed into a box of appropriate size keep refining
		until ref1_ordered_width < threshold and ref2_ordered_width < threshold
			#interpolate:
			ref1_interpset = (0..ref1_ordered.length-1).map{|i| ref1_ordered[i] + [i]}
		#	@log.debug("Tools.refine: ref1_interpset\n#{ref1_interpset.map{|x| x.join(",")}.join("\n")}")
			ref1_spline = self.interpolate(ref1_interpset,points).map{|x| [x[0],x[1]]}
			ref2_interpset = (0..ref2_ordered.length-1).map{|i| ref2_ordered[i] + [i]}
		#	@log.debug("Tools.refine: ref2_interpset\n#{ref2_interpset.map{|x| x.join(",")}.join("\n")}")
			ref2_spline = self.interpolate(ref2_interpset,points).map{|x| [x[0],x[1]]}

			#find min
			ref_pairs = ref1_spline.product(ref2_spline)
			ref_dist = ref_pairs.map{|x| self.latlondist(x[0][0],x[0][1],x[1][0],x[1][1])}
			min_index = ref_dist.index(ref_dist.min)
			@log.debug("Tools.refine: Minimum occured @ #{ref_pairs[min_index].join(",")}")
			ref1_min = ref_pairs[min_index][0]
			ref2_min = ref_pairs[min_index][1]
			
			#pick neighbords ref1 if we need to shrink
			if  ref1_ordered_width > threshold
				@log.debug("Tools.refine: ref1 needed refinement")
				ref1_ordered = self.pick_triple(ref1_spline,ref1_spline.index(ref1_min))
			end

			#pick neighbords ref2 if we need to shrink
			if  ref2_ordered_width > threshold
				@log.debug("Tools.refine: ref2 needed refinement")
				ref2_ordered = self.pick_triple(ref2_spline,ref2_spline.index(ref2_min))
			end
			
			#update the distnaces variables
			ref1_ordered_width = self.latlondist(ref1_ordered.first[0],ref1_ordered.first[1],ref1_ordered.last[0],ref1_ordered.last[1])
			ref2_ordered_width = self.latlondist(ref2_ordered.first[0],ref2_ordered.first[1],ref2_ordered.last[0],ref2_ordered.last[1])
		end

		result = [ref1_ordered,ref2_ordered]

		return result
	end

	def self.pick_triple(curve,index)
		#Given a curves, pick_triple will return the point at index and it's nearest neighbors 
		middle = curve[index]
		#fan out from the min and find the nearest distinct points for curve1, here ordering matters because I want a consequtive set
		if middle == curve.first
			@log.debug("Tools.pick_triple: Shifting from the front of the curve #{middle.join(",")}")
			upper = middle
			middle = curve[1]
			lower = curve[2]
		elsif middle == curve.last
			@log.debug("Tools.pick_triple: Shifting from the back of the curve #{middle.join(",")}")
			lower = middle
			middle = curve[-2]
			upper = curve[-3]
		else
			@log.debug("Tools.pick_triple: In the middle of the curve #{middle.join(",")}")
			upper = curve[curve.index(middle)+1]
			lower = curve[curve.index(middle)-1]
		end
		result = [lower,middle,upper]
		return result
	end


	def self.intersect(c1,c2,threshold=0.025, points=25)
		#c1 and c2 are two sets of 2 tuples of lat/lon (no time, index# will be the indpendtant variable). Threshold is a distance below which we check for intersections
		#Points = number of points in the interpolation to calculate. Returns  an array of possible intersections and their distance to the nearest endpoint of c1/c2 or nil if nothing comes close

		@log.debug("Tools.intersect: Checking for an intersection between\n#{c1.map{|x| x.join(",")}.join("\n")}\nand\n#{c2.map{|x| x.join(",")}.join("\n")}")

		#I'll first find the min pair and it's nearest neighbors. Using only 3 points should hopefully prevent me from Strange interpolation errors because the points are out of order.
		#Even if they are out of 
		pairs = c1.product(c2)

		#check for an existng intersection
		common = pairs.select{|x| x[0][0] == x[1][0] && x[0][1] == x[1][1]}

		#multiple intersections would be bad
		if common.length > 1
			@log.debug("Tools.intersect: Too many intersections found:\n#{common.inject(String.new){|m,c| m + c.join(",") + "\n"}}")
			raise TooManyIntersections,"More than one point in common in this pair of splines" 
		end
		if common.length == 1
			@log.debug("Tools.intersect: Exact match found")
			return common.first[0]
		end
		
		#compute a matirx of distances
		dist_mat = pairs.map{|x| self.latlondist(x[0][0],x[0][1],x[1][0],x[1][1])}
		@log.debug("Tools.intersect: First 5 closest pairs are\n#{dist_mat.sort.first(5).map{|x| pairs[dist_mat.index(x)]}.map{|x| "#{x[0][0]},#{x[0][1]}\n#{x[1][0]},#{x[1][1]}"}.join("\n")}")

		if dist_mat.min < threshold
			@log.debug("Tools.intersect: Found something below the threshold, investigating further")

			#generate a list of cloest pairs
			pairs = c1.product(c2)
			dist_mat = pairs.map{|x| self.latlondist(x[0][0],x[0][1],x[1][0],x[1][1])}
			min_inds = dist_mat.each_with_index.select{|x| x[0] < threshold}.sort{|a,b| a[0]<=>b[0]}
			closest_pairs = min_inds.map{|i| [pairs[i[1]][0],pairs[i[1]][1]]}
			@log.debug("Tools.intersect: Number of closest pairs#{closest_pairs.length}")
		
			#generate a list of triples
			c1_ord = self.order_curve(c1)	
			c2_ord = self.order_curve(c2)
			triples = closest_pairs.map{|pair| [self.pick_triple(c1_ord,c1_ord.index(pair[0])),self.pick_triple(c2_ord,c2_ord.index(pair[1]))]}
			@log.debug("Tools.intersect: Number of triples #{triples.length}")

			#refine the triples so that their sepration is below the threshold, so all points are within the square with threshold length sides
			refinement = triples.map{|triple| self.refine(triple[0],triple[1],threshold,points)}
			@log.debug("Tools.intersect: Number of refined trples #{refinement.length}")

			#see if any of the refinements actually intersect
			candidates = refinement.map{|ref| self.line_intersect([ref[0].first,ref[0].last,ref[1].first,ref[1].last])}.compact
			@log.debug("Tools.intersect: Number of candidates#{candidates.length}")
			if candidates.empty?
				@log.debug("Tools.intersect: No Intersection found")
				return nil
			else
				all = c1 + c2
				partial = candidates.map{|y| [y,all.map{|x| self.latlondist(y[0],y[1],x[0],x[1])}.min]}.sort{|x,y| x[1]<=>y[1]}
				result = partial.select{|x| x[1] < threshold}
				if result.empty?
					@log.debug("Tools.intersect: Intersections found, but none within threshold closet was #{partial.first[1]}")
					return [[false,partial.first[1]]]
				else
					return result
				end
			end
		else
			@log.debug("Tools.intersect: No points below the threshold distance")
			return nil
		end
	end

	def self.extrapolate(curve,points)
		#curve is a collection of lat lon pairs, this tool will extend the edges linearly by looking at only the last two end points. 
		#it will extend out points number of independant variables, where points is a small int.
		raise "Tools.extrapolate: Can't extrapolate less that 2 points" if curve.length < 2
		#order the curve to get the furtherest ends sperated
		ocurve = self.order_curve(curve)

		#Bulild a line on the left and right sides
		left = LatLonLine.new([[ocurve[0][0],ocurve[0][1],0],[ocurve[1][0],ocurve[1][1],1]],@log)
		right = LatLonLine.new([[ocurve[-2][0],ocurve[-2][1],0],[ocurve[-1][0],ocurve[-1][1],1]],@log)

		#extrapolate
		left_ext = (1..points).map{|i| left.eval_point(-i)}
	
		right_ext = (1..points).map{|i| right.eval_point(i+1)}
	

		#combine
		return left_ext + curve + right_ext
	end

	def self.order_curve(curve,argpick=nil)
		#curve is a tuple of lat/lons. Pick is a single lat/lon pair that is the first point in the list.
		#This functions picks the first point and the orders the elements by distance from the first point, 
		#then it checks the last point and does the same ("in reverse"). The two orderings should match. 
		#It will throw out a message if it does not match the original, and will return #an ordered copy or nil
		
		if argpick.nil?
		#find the furthest endpoints 

		far = curve.product(curve).map{|arr| arr + [self.latlondist(arr[0][0],arr[0][1],arr[1][0],arr[1][1])]}.sort{|x,y| x[2]<=>y[2]}.last


		#pick the one cloest to one of the ends
		pick  = [far[0],far[1]].product([curve.first,curve.last]).map{|arr| arr + [self.latlondist(arr[0][0],arr[0][1],arr[1][0],arr[1][1])]}.sort{|x,y| x[2]<=>y[2]}.first[0]
		else
			pick = argpick
		end


		sub_curve = curve.select{|x| x != pick}


		#assemble array by shortest next neighbor distance 
		res_curve = Array.new()

		#find the cloest to pick
		res_curve.push(sub_curve.delete_at(sub_curve.map{|point| self.latlondist(point[0],point[1],pick[0],pick[1])}.each_with_index.min[1]))
		
		until sub_curve.empty?
			#find the lowest element and push that into the result array
			res_curve.push(sub_curve.delete_at(sub_curve.map{|point| self.latlondist(point[0],point[1],res_curve.last[0],res_curve.last[1])}.each_with_index.min[1]))
		end

		#figure out which end to tack the first point too
		if !argpick.nil?
			#perhaps you had some context to know which end was the starting end, in which case your decision overides

			res_curve.unshift(pick)
		elsif self.latlondist(pick[0],pick[1],res_curve.first[0],res_curve.first[1]) > self.latlondist(pick[0],pick[1],res_curve.last[0],res_curve.last[1])
			#the "back" is closer so push it in there

			res_curve.push(pick)
		else

			#the "front" is closer so unshift it in there
			res_curve.unshift(pick)
		end

		#compute the average node distance
		curve_dist_avg = curve[0..-2].zip(curve[1..-1]).map{|arr| self.latlondist(arr[0][0],arr[0][1],arr[1][0],arr[1][1])}.inject(0, :+)
		res_curve_dist_avg = res_curve[0..-2].zip(res_curve[1..-1]).map{|arr| self.latlondist(arr[0][0],arr[0][1],arr[1][0],arr[1][1])}.inject(0, :+)
		@log.debug("Tools.order_curve: Average per term distance, Original:#{curve_dist_avg}, and resultant: #{res_curve_dist_avg}")

		if res_curve_dist_avg < curve_dist_avg

			return res_curve
		else

			return curve
		end
	end


	def self.make_intersection(c1,c2,dthreshold=0.025,pthreshold=nil)
		#c1 and c2 are arrays of 2 tuples lat/lon pairs, the curves that we will generate an intersection for.
		#First we check for an intersection, it it exists we're done, if not find the closeest ends and extend to some dthreshold.
		@log.debug("Tools.make_intersection: Attempting to intersect curves of length #{c1.length} and #{c2.length}")

		#precheck to save some calculations
		begin
			inter = self.intersect(c1,c2)
		rescue TooManyIntersections => e
			@log.debug("Tools.make_intersection: These roads intersect in too many places, try a smaller set")
			raise
		end
		unless inter.nil?
			@log.debug("make_intersection: Original curvers already intersect at #{inter.join(",")}") 
			raise AleadyConnected.new(inter), "Already Connected at #{inter.join(",")}"
		end
	
		#calcualate a pthreshold if none given
		if pthreshold.nil?
			@log.debug("Tools.make_intersection: No pthreshold given, calculating one from dthrehold")
			c1_ord = self.order_curve(c1)
			c2_ord = self.order_curve(c2)
			dists = [[c1_ord[0],c1_ord[1]],[c2_ord[0],c2_ord[1]],[c1_ord[-1],c1_ord[-2]],[c2_ord[-1],c2_ord[-2]]].map{|x| self.latlondist(x[0][0],x[0][1],x[1][0],x[1][1])}
			@log.debug("Tools.make_intersection:threholds dists #{dists.join(",")}")
			pthreshold = (dthreshold / (dists.inject(:+) / 4.0 )).ceil
			@log.debug("Tools.make_intersection: calculated pthreshold = #{pthreshold}")
		end
		

		#extrapolate ends
		c1_ext = self.extrapolate(c1,pthreshold)
		c2_ext = self.extrapolate(c2,pthreshold)

		#check for an intesection
		inter = self.intersect(c1_ext,c2_ext)

		if inter.nil?
			raise CantConnect,"make_intersection: Couldn't make intersection within #{pthreshold} extrapolated points, no candidates"
		elsif inter.first[0] == false
			raise CantConnect,"make_intersection: Couldn't make an intersection with #{dthreshold} of any end point, cloest was #{inter.first[1]}"
		else
			return inter.first[0]
		end
	end
end

if __FILE__ == $0
	begin
		#LOG instance static constant
		OPTIONS = Hash.new()
		LOG = Logger.new(STDOUT)
		$optparse = OptionParser.new do |opts|

			opts.banner = "Usage: Library or CLI:"
			opts.separator "Library: Use the Tools.latlondist() function to calculate distances"
			opts.separator "Library: NOTE you MUST use Tools.set_log(logger_object) to set the log file before first use or this lib will throw an error"
			opts.separator "CLI: Calculates the distance between given Lat/Lon Pairs"
			opts.separator "Lib-Dist [OPTIONS]"

			#DEBUG level
			OPTIONS[:debug] = false
			opts.on('-d','--debug','Enable Debug messages (default: false)') do
				OPTIONS[:debug] = true
			end
		
			#minlat
			OPTIONS[:minlat] = nil
			opts.on('-x','--minlat MINLAT',Float, '(Default = nil) Minimum Latitude') do |minlat|
				OPTIONS[:minlat] = minlat.to_f
			end
	
			#minlon
			OPTIONS[:minlon] = nil
			opts.on('-y','--minlon MINLON',Float,'(Default = nil) Minimum Longitude') do |minlon|
				OPTIONS[:minlon] = minlon.to_f
			end
	
			#maxlat
			OPTIONS[:maxlat] = nil
			opts.on('-X','--maxlat MAXLAT',Float,'(Default = nil) Maximum Latitude') do |maxlat|
				OPTIONS[:maxlat] = maxlat.to_f
			end
	
			#maxlon
			OPTIONS[:maxlon] = nil
			opts.on('-Y','--maxlon MAXLON',Float,'(Default = nil) Maximum Latitude') do |maxlon|
				OPTIONS[:maxlon] = maxlon.to_f
			end
		
			#test the intersectio library	
			OPTIONS[:intdebug] = false
			opts.on('-I','--intdebug','Enable Intersection Debug (default: false)') do
				OPTIONS[:intdebug] = true
			end

			#help message
			opts.on( '-h', '--help', 'Display this screen' ) do
				puts opts
				exit
			end
		end
		$optparse.parse!
		OPTIONS[:debug] ? LOG.level = Logger::DEBUG : LOG.level = Logger::INFO
		Tools.set_log(LOG)	

		unless OPTIONS[:minlat].nil?
			LOG.info("Distance computed was #{Tools.latlondist(OPTIONS[:minlat], OPTIONS[:minlon], OPTIONS[:maxlat], OPTIONS[:maxlon])} miles")
		end
		if OPTIONS[:intdebug]
			x = [[40.525057,-74.454765],[40.525082,-74.454588],[40.525526,-74.452308]]
			y = [[40.525257,-74.454851],[40.525759,-74.455119],[40.526795,-74.455666]]
			LOG.info("####################################################################################################")
			LOG.info("Building an intersection between \n#{x.inject(String.new){|m,c| m + c.join(",") + "\n"}} and \n#{y.inject(String.new){|m,c| m + c.join(",") + "\n"}}")
			int = Tools.make_intersection(x,y)
			LOG.info("Intersection was made at #{int.join(",")}")
		end
	rescue AleadyConnected => f
		LOG.fatal(f.message)
		LOG.fatal("Caught an Already Connected exception. The intersection was #{f.inter.join(",")}")
	rescue => e
		LOG.fatal(e.message)
		raise
	ensure
		LOG.close
	end
end

