################################################################################
# There are two types of pathing errors:
#
# Path A errors (cannot make turn)
# We correct the path by either shrinking or expanding the path since the last
# point of interest. Try both! Expanding can complete immediately and move back
# some number of samples. Shrinking needs to read in more samples until something
# that fits in is found. Don't forget to mark the location of interest
# afterwards.
#
# Path B errors (speed hits zero without cause)
# Need to find an intersection -- again we can compress or expand the path
# previous to this point, but now we are looking for any intersection.
#
#                               Speed Data
#                        -----------------------
#                        | Turn,Stop | Straight
#    -------------------------------------------
#         | Straight, no | B         | OK
#    Road | Intersection |           |
#         | ------------------------------------
#         | High Angle   | OK        | A
#    -------------------------------------------
#
################################################################################

#In places with ice the max elevation is usually 8% (Roess et al.)
DEFAULT_ELEVATION = 0.08

#Interpolate the last few values (15, 25, 35, 45)
DRY_SIDE_FRICTION = {10 => 0.45, 20 => 0.4, 30 => 0.35, 40 => 0.3, 50 => 0.26,
  55 => 0.22, 60 => 0.19, 65 => 0.18, 70 => 0.17, 75 => 0.16, 80 => 0.15, 85 => 0.14,
  15 => 0.425, 25 => 0.375, 35 => 0.325, 45 => 0.28};

#Maximum lane width (in the US) is 12 feet
#Source: A Policy on Geometric Design of Highways and Streets, AASHTO
LANE_WIDTH = 12

def milesToFeet(miles)
  return miles*5280.0
end

#Return the minimum turn radius for a dry road with slight incline
#at the given speed
def safeTurnRadius(speed)
  #Any turn can be taken at slow speeds
  if (speed < 10.0)
    return 0;
  elsif (speed > 80)
    #For now we'll assume that speeds are capped at 85mph
    speed = 85;
  end

  map_speed = ((speed / 5).to_i)*5
  friction = DRY_SIDE_FRICTION[map_speed]

  #From Roess et al
  speed**2 / (15 * (0.01 * DEFAULT_ELEVATION + friction))
end

#Use the number of lanes crossed and the turn angle to determine a turn radius
#Uses the same unit as the lane sizes, which is feet
def turnRadius(start_lanes, end_lanes, way_changes, turn_angle, step_dist, prev_step_dist)
  #Turn in the same road. Use the step distance to calculate the turn radius
  #Also use this kind of turn for any kind of *_link or motorway_junction
  #because these are high-speed ramps that curve rather than making hard turns
  #The map data doesn't seem to have labelled a lot of the ramps
  #leading onto major roads (eg. route 1) so also check the angle here and
  #if the angle is less than 30 assume that this is a ramp.
  if (turn_angle < 30)
    way_changes = false
  end
  if (step_dist == 0.0 or prev_step_dist == 0.0)
    return 0.0;
  end
  if (not way_changes)
    #Convert from miles to feet for the turn radius
    step_dist = milesToFeet(step_dist)
    prev_step_dist = milesToFeet(prev_step_dist)

    #The road is curved, not a hard turn, so see how many steps fit into
    #360 degrees, treat the distance as a circle's curcumference
    #and calculate the radius
    steps = 360.0 / turn_angle.abs
    radius = steps*step_dist / (2.0*Math::PI)

  else
    #In this case the step distance is not the turning distance because the
    #road is making a single, sharp turn rather than a gradual curve
    #Assume that a driver always makes a smooth curve (as in along the
    #circumference of a circle) so we can just find the distance moved
    #by considering this path as a triangle inscribed in a circle.
    #Flipping the triangle over the x-axis creates a circular segment.
    #The equation for a radius of a circle given a circule segment is
    #r = h/2 + c**2 / 8h
    #where h is the heigh of the segment (from the chord to the circle's edge)
    #and c is the length of the chord forming the base of the segment.
    #h is the horizontal number of lanes crossed, and c is twice the
    #number of vertical lanes crossed
    #Use the number of lanes crossed to determine the turn radius
    #First case: right turn
    if (0 < turn_angle)
      #Turn over the starting lane to at most the number of lanes in the second road
      actual_distance = LANE_WIDTH*(1 + end_lanes)
      h = LANE_WIDTH
      c = 2 * end_lanes * LANE_WIDTH
    else
      #Left turns cover the lanes on the far side of the starting road, the
      #initial lane, and the lanes in the new way
      actual_distance = LANE_WIDTH*(1 + start_lanes + 2*end_lanes)
      h = (1+start_lanes)*LANE_WIDTH
      c = 2 * 2 * end_lanes * LANE_WIDTH
    end
    #Again, the equation for a radius of a circle given a circule segment is
    #r = h/2 + c**2 / 8h
    radius = h / 2.0 + c**2 / (8*h)
  end
  return radius
end

#Haversine distance in miles (used to find actual distances between GSP coordinates)
def haversine_mi(node_a, node_b)
  lat1 = node_a.lat
  lon1 = node_a.lon
  lat2 = node_b.lat
  lon2 = node_b.lon
  @d2r = Math::PI / 180.0
  dlon = (lon2 - lon1) * @d2r;
  dlat = (lat2 - lat1) * @d2r;
  a = Math.sin(dlat/2.0)**2 + Math.cos(lat1*@d2r) * Math.cos(lat2*@d2r) * Math.sin(dlon/2.0)**2;
  c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a));
  #Multiply by the radius of the earth (in miles here)
  return 3956 * c; 
end


#Constants for turn evaluation
NO_TURN = 0
TURN_POSSIBLE = 1
FUTURE_TURN_POSSIBLE = 2
def turnPossible(speed, speed_delta, angle, intersection)
  if (intersection and speed < 25.0 and speed_delta <= -2.0) then
    return TURN_POSSIBLE
  elsif (not intersection and speed < 25.0 and speed_delta <= -2.0) then
    return FUTURE_TURN_POSSIBLE
  else
    return NO_TURN
  end
end


#Rewind the A error by expanding samples from the last landmark to the current
#point. This assumes that the recorded distance travelled is less than the
#actual distance covered.
#Returns the expansion factor and the new sample index when rewinding works,
#nil otherwise.
def rewindAError(epath, turn_radius, new_node)
  #The time_index of the path will move backwards because we will reach this
  #point sooner. Find the first spot where the turn radius of the turn is
  #achievable with the given speed (less three to allow for measurement error)
  #puts "new #{epath.time_index}+#{epath.speed_samples.length}"
  if (epath.time_index>=epath.speed_samples.length)
    return nil
  end
  while (epath.time_index > epath.lastLandmarkTime and
         turn_radius < safeTurnRadius(epath.speed_samples[epath.time_index].speed - 3))
    epath.time_index -= 1
  end
  #When this happens the expansion factor is undefined so the path is
  #impossible
  if (epath.time_index == epath.lastLandmarkTime)
    return nil
  end
  #Otherwise we can just count the ratio of the distance we would need to reach
  #this sample at this location to the distance that the path thinks it has
  #travelled to find the expansion factor.
  sample_distance = epath.speed_samples[epath.lastLandmarkTime,epath.time_index].inject(0.0){|sum,sample|
    sum += sample.movement
  }
  #Set the landmark at the current time given this compression factor
  #This should be greater than one since we expanded the path
  epath.setLandmark(epath.segment_dist/sample_distance)
  #Return this new path with a new landmark at this fixed location
  epath.addPoint(new_node)
  return epath
end

#Advance the A error by compressing samples from the last landmark to the
#current point. This assumes that the recorded distance travelled is more than
#the actual distance covered so more samples fit into that space.
#Returns the compression factor and the new sample index when compression works,
#nil otherwise.
def advanceAError(epath, turn_radius, new_node, logfile)
  #The time_index of the path will move forwards because we will reach this
  #point later. Find the first spot where the turn radius of the turn is
  #achievable with the given speed (less three to allow for measurement error)
  initial_t_index = epath.time_index
  while (epath.time_index < epath.speed_samples.length and
         turn_radius < safeTurnRadius(epath.speed_samples[epath.time_index].speed - 3))
    epath.time_index += 1
  end
  #When this happens the compression factor is undefined so the path is
  #impossible
  if (epath.time_index == epath.speed_samples.length)
    return nil
  end
  #Otherwise we can just count the ratio of the distance we would need to reach
  #this sample at this location to the distance that the path thinks it has
  #travelled to find the compression factor.
  sample_distance = epath.speed_samples[epath.lastLandmarkTime,epath.time_index].inject(0.0){|sum,sample|
    sum += sample.movement
  }
  logfile.puts "advanceAError: advancing from time index #{initial_t_index} to #{epath.time_index} changing initial distance from #{epath.segment_dist} to #{sample_distance}"
  #Set the landmark at the current time given this compression factor
  #This should be less than one since we needed to use more samples in the same time
  epath.setLandmark(epath.segment_dist/sample_distance)
  #Return this new path with a new landmark at this fixed location
  epath.addPoint(new_node)
  return epath
end

#Rewind the B error by compressing samples from the last landmark to the current
#point. This assumes that the recorded distance travelled is less than the
#actual distance covered.
#Returns the compression factor and the new sample index when rewinding works,
#nil otherwise.
def rewindBError(epath, navigator)
  #Look for the nearest previous intersection along the path, find the
  #compression factor from the last landmark, compress the distance
  #from the landmark to there.
  #First find the last intersection, drop the points from the path after that,
  #and compare the segment distance to the distance from the last landmark
  #to the stopping point before the intersection (# of lanes + gutter length)

  distance_reduction = 0.0
  path_idx = -1
  while (0 < path_idx and
         1 >= navigator.nextPoints(epath.path[path_idx-1], epath.path[path_idx]).length)
    path_idx -= 1
    #Failure if we have backed up to the last landmark
    distance_reduction += epath.path[path_idx].distance(epath.path[path_idx+1])
    if (distance_reduction >= epath.curSegmentDistance)
      return nil
    end
  end
  #Failure case: no more nodes
  if (0 == path_idx)
    return nil
  end
  #Also need to back up at least one lane's width from the inersection since
  #we cannot stop in the middle of it.
  #Convert lane width in feet into miles (5280 feet in a mile)
  distance_reduction += LANE_WIDTH/5280.0
  #Recheck that distance reduction does not hit the landmark
  if (distance_reduction >= epath.curSegmentDistance)
    return nil
  end

  #Now drop all of the path that is beyond this intersection since we are
  #now assuming that the path did not reach those points.
  epath.path = epath.path[0..path_idx]
  #Now set a landmark at this spot
  epath.setLandmark(epath.segment_dist/(epath.segment_dist - distance_reduction))
  return epath
end

#Advance the B error by expanding samples from the last landmark to the
#current point. This assumes that the recorded distance travelled is more than
#the actual distance covered.
#Returns the expansion factor and the new sample index when compression works,
#nil otherwise.
def advanceBError(epath, navigator)
  #Look for the nearest next intersection along the path, find the
  #expansion factor from the last landmark.
  #First find the last intersection, adding any path points that are encountered
  #that are not part of an intersection.

  while (1 >= navigator.pathIntersects(epath).length)
    nex = navigator.pathIntersects(epath).first
    if (nil == nex)
      return nil
    end
    #The addPoint function adjusts the distance to this node, stored in
    #the epath.progress variable, so we can check the distance increase
    #at the very end
    epath.addPoint(nex)
  end
  #Also need to back up at least one lane's width from the inersection since
  #we cannot stop in the middle of it.
  #Convert lane width in feet into miles (5280 feet in a mile)
  distance_increase = epath.progress - LANE_WIDTH/5280.0
  epath.progress = -1 * LANE_WIDTH/5280.0

  #Now set a landmark at this spot
  epath.setLandmark(epath.segment_dist/(epath.segment_dist + distance_increase))
  return epath
end

#Find the angle of turn given the previous node, current node, and next node
#A negative angle indicates a left turn.
def turnAngle(prev, cur, nex)
  adj = prev.distance(cur)
  opp = cur.distance(nex)
  tan = prev.distance(nex)
  #Now apply the law of cosines to find the turn angle
  tan_opp = (adj*adj + opp*opp - tan*tan)/(2 * adj * opp)
  #Convert to degrees
  #(take the real part to avoid strange errors when an imaginary part is generated)
  angle = (180.0 - 180.0 * Math.acos(tan_opp) / Math::PI).real
  #Now determine if this is a left or right turn using a cross product of the
  #two vectors. See http://en.wikipedia.org/wiki/Graham_scan
  #The equation is (x2-x1)(y3-y1)-(y2-y1)(x3-x1)
  #0 => linear, positive => left turn, negative => left turn
  #longitudes are the x value, latitudes are the y value
  #Need to multiply the longitude by -1 because this is from North America
  turn = (cur.lon - prev.lon)*(nex.lat - prev.lat) - (cur.lat - prev.lat)*(nex.lon - prev.lon)
  if (0 < turn)
    return -1 * angle
  else
    return angle
  end
end

