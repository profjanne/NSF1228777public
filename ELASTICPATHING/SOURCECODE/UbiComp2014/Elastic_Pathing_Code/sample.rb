################################################################################
# Define the Sample class.
# Used to store time/speed/delta speed samples.
################################################################################

#Defining some classes for processing
#Speed and time values are derived from the GPS trace
class Sample
  attr_accessor :time, :speed, :movement, :speed_delta, :time_delta, :speed_minimum
  def initialize(time, speed, movement, sdelta, tdelta, sminimum = 0)
    @time = time
    @speed = speed
    @movement = movement
    @speed_delta = sdelta
    @time_delta = tdelta
    @speed_minimum = sminimum
  end

  
  def to_s
    "#{time}: #{speed} (movement #{movement}, delta speed #{speed_delta}, minimum #{speed_minimum})"
  end
end

