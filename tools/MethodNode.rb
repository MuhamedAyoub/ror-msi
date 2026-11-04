class MethodNode

    attr_reader :method_name , :method_args , :classNode 
    attr_accessor :called_methods

    def initialize(classNode , method_name , method_args , called_methods = [] )
        @classNode = classNode 
        @method_name = method_name
        @method_args = method_args
        @called_methods = called_methods
    end

    def add_called_method(called_method)
        @called_methods << called_method
    end

    def set_called_methods( called_methods )
        @called_methods = called_methods
    end

    def get_called_methods
        @called_methods
    end

    def get_method_name
        @method_name
    end

    def get_method_arg 
        @method_args
    end


end