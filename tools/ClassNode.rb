
class ClassNode

    attr_reader :class_name , :module_name , :data_entities , :type
    attr_accessor :method_list

    def initialize(class_name , module_name = "" , type = ClassType::ClassController , method_list , data_entities , called_methods )
        @class_name = class_name 
        @module_name = module_name
        @type = type
        @method_list = [] 
        method_list.each do | method|   
            method_name = method[:name]
            if called_methods.key?(method_name)
                called = called_methods[method_name]
            else
                called = []
            end
            @method_list << MethodNode.new(self , method_name , method[:num_args] , called)
        end   
        @data_entities = data_entities  
    end

    def has_method?(called_method)
        @method_list.any? { |methodNode| methodNode.method_name == called_method[:name].to_s  && methodNode.method_args == called_method[:num_args]}
    end


end