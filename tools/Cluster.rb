class Cluster
    attr_accessor :name, :class_names
  
    def initialize(name, class_names)
      @name = name
      @class_names = class_names
    end
  end