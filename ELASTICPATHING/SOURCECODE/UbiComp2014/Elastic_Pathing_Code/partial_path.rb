################################################################################
# Define the PartialPath class.
# Used during pathing to remember the path and progress in the speed samples.
################################################################################

require './path'
require './sample'

class PartialPath
  attr_accessor :path, :speed_samples
  attr_reader :time_index

  #Initialize with a path and the speed samples for tracing,
  #initialize an index at 0 since we start at the first speed sample.
  def initialize(path, speed_samples, position = 0)
    @path          = path
    @speed_samples = speed_samples
    #Current index into the speed samples
    @time_index = position
  end

  def getAndAdvanceFrame
    @time_index += 1
    if (@time_index >= @speed_samples.length)
      return @path, nil
    end
    return @path, @speed_samples[@time_index-1]
  end
end

