def format_calls_architecture(classNode)

    calls_architecture = []

    classNode.method_list.each do |methodNode|
        called_methods_list = methodNode.called_methods 
        formatted_method = {
            calling_method: methodNode.method_name ,
            called_methods: called_methods_list,
        }
        calls_architecture << formatted_method
    end

    return calls_architecture
end

def singularize(word)
    case word
    when /s$/
      # Remove the 's' at the end and lowercase the first letter
      word.chomp('s').capitalize
    else
      # Add more transformation rules if needed
      word
    end
  end