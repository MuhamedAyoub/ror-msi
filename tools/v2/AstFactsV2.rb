# AstFactsV2 — per-file AST fact extraction for the v2 resolver (plan WP1/WP3).
#
# Differences from tools/ASTExtractor.rb (which is left untouched):
#   * fully qualified class names (Api::V1::User), multiple classes per file
#   * every call record carries its receiver (kind + name/summary) — the join
#     that v1 threw away
#   * arity intervals [min, max] instead of a single formal-arg count
#   * superclass / include / extend / prepend facts (mixin lattice for L2)
#   * assignment records (lvasgn/ivasgn) so L1 can type receivers
#   * Rails macros parsed with their options, including `as:` and
#     `polymorphic:` on both association sides
require 'parser/current'

module V2
  INF = Float::INFINITY

  ClassFacts = Struct.new(
    :qualified_name,   # "Api::V1::User"
    :namespace,        # ["Api", "V1"]
    :file, :role,
    :superclass,       # raw const string or nil
    :mixins,           # ["Concerns::Taggable", ...] from include/extend/prepend
    :defs,             # [{name:, min:, max:, static:}]
    :calls,            # [{name:, num_args:, recv:, in_method:}]
    :macros,           # [{kind:, ...}] associations/scope/delegate/alias/define_method
    :assigns,          # [{scope: method|:ivar, var:, rhs:}]  rhs = receiver summary
    keyword_init: true
  )

  class AstFactsV2
    attr_reader :classes

    def initialize(file, role)
      @file = file
      @role = role
      @classes = []
    end

    def self.parse_file(path, role)
      source = File.read(path)
                   .force_encoding('UTF-8')
                   .encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
                   .gsub(/[\x00-\x08\x0B\x0C\x0E-\x1F]/, '')
      buffer = Parser::Source::Buffer.new(path).tap { |b| b.source = source }
      ast = Parser::CurrentRuby.new.parse(buffer)
      return [] if ast.nil?
      f = new(path, role)
      f.walk(ast, ns: [], klass: nil, meth: nil)
      f.classes
    rescue Parser::SyntaxError, EncodingError, StandardError => e
      warn "[AstFactsV2] skipping #{path}: #{e.class}: #{e.message[0..120]}"
      []
    end

    ASSOC_MACROS = %i[belongs_to has_many has_one has_and_belongs_to_many].freeze
    MIXIN_MACROS = %i[include extend prepend].freeze

    def walk(node, ctx)
      return unless node.is_a?(Parser::AST::Node)
      case node.type
      when :module
        name = const_string(node.children[0])
        walk_children(node.children[1..], ctx.merge(ns: ctx[:ns] + split_const(name)))
      when :class
        name = const_string(node.children[0])
        parts = split_const(name)
        ns    = ctx[:ns] + parts[0..-2]
        cf = ClassFacts.new(
          qualified_name: (ns + [parts[-1]]).join('::'),
          namespace: ns, file: @file, role: @role,
          superclass: const_string(node.children[1]),
          mixins: [], defs: [], calls: [], macros: [], assigns: []
        )
        @classes << cf
        walk_children([node.children[2]], ctx.merge(ns: ns + [parts[-1]], klass: cf, meth: nil))
      when :def
        record_def(ctx[:klass], node.children[0], node.children[1], static: false)
        walk_children([node.children[2]], ctx.merge(meth: node.children[0].to_s))
      when :defs # def self.x
        record_def(ctx[:klass], node.children[1], node.children[2], static: true)
        walk_children([node.children[3]], ctx.merge(meth: node.children[1].to_s))
      when :send, :csend
        handle_send(node, ctx)
        walk_children(node.children, ctx)
      when :lvasgn
        record_assign(ctx, node.children[0].to_s, node.children[1])
        walk_children(node.children[1..], ctx)
      when :ivasgn
        record_assign(ctx, node.children[0].to_s.delete_prefix('@'), node.children[1], ivar: true)
        walk_children(node.children[1..], ctx)
      when :or_asgn, :op_asgn # @x ||= expr
        lhs, *rest = node.children
        rhs = rest.last
        if lhs.is_a?(Parser::AST::Node)
          if lhs.type == :ivasgn
            record_assign(ctx, lhs.children[0].to_s.delete_prefix('@'), rhs, ivar: true)
          elsif lhs.type == :lvasgn
            record_assign(ctx, lhs.children[0].to_s, rhs)
          end
        end
        walk_children(node.children, ctx)
      else
        walk_children(node.children, ctx)
      end
    end

    private

    def walk_children(children, ctx)
      (children || []).each { |c| walk(c, ctx) if c.is_a?(Parser::AST::Node) }
    end

    def record_def(klass, name, args_node, static:)
      return unless klass
      min = 0; max = 0; open = false
      (args_node&.children || []).each do |a|
        case a.type
        when :arg          then min += 1; max += 1
        when :optarg       then max += 1
        when :restarg, :kwrestarg then open = true
        when :kwarg, :kwoptarg    then max += 1 # kwargs arrive as one hash; be permissive
        end
      end
      klass.defs << { name: name.to_s, min: min, max: (open ? INF : max), static: static }
    end

    def record_assign(ctx, var, rhs, ivar: false)
      return unless ctx[:klass] && rhs.is_a?(Parser::AST::Node)
      summary = summarize(rhs)
      return if summary.nil?
      ctx[:klass].assigns << {
        scope: ivar ? :ivar : (ctx[:meth] || :class_body),
        var: var, rhs: summary
      }
    end

    def handle_send(node, ctx)
      klass = ctx[:klass]
      return unless klass
      receiver, mname, *args = node.children
      m = mname.to_s

      # ---- class-body macros ----
      if receiver.nil? && ctx[:meth].nil?
        if ASSOC_MACROS.include?(mname)
          klass.macros << assoc_macro(mname, args)
          return
        elsif MIXIN_MACROS.include?(mname)
          args.each do |a|
            c = const_string(a)
            klass.mixins << c if c
          end
          return
        elsif mname == :scope && args[0]&.type == :sym
          klass.macros << { kind: :scope, name: args[0].children[0].to_s }
          return
        elsif mname == :delegate
          names = args.select { |a| a.type == :sym }.map { |a| a.children[0].to_s }
          to = nil
          opts = args.find { |a| a.type == :hash }
          opts&.children&.each do |pair|
            k, v = pair.children
            to = v.children[0].to_s if k.type == :sym && k.children[0] == :to && %i[sym str].include?(v.type)
          end
          klass.macros << { kind: :delegate, methods: names, to: to } if to
          return
        elsif mname == :alias_method && args.size >= 2 && args[0].type == :sym && args[1].type == :sym
          klass.macros << { kind: :alias, new: args[0].children[0].to_s, old: args[1].children[0].to_s }
          return
        elsif mname == :define_method && args[0]&.type == :sym
          klass.macros << { kind: :define_method, name: args[0].children[0].to_s }
          return
        end
      end

      # ---- ordinary call record, receiver joined ----
      n_args = args.reject { |a| a.type == :block_pass }.size
      klass.calls << {
        name: m, num_args: n_args,
        recv: summarize(receiver),
        in_method: ctx[:meth]
      }
    end

    def assoc_macro(macro, args)
      rec = { kind: macro.to_s.to_sym, name: nil, class_name: nil,
              polymorphic: false, as: nil, through: nil }
      rec[:name] = args[0].children[0].to_s if args[0]&.type == :sym
      opts = args.find { |a| a.is_a?(Parser::AST::Node) && a.type == :hash }
      opts&.children&.each do |pair|
        k, v = pair.children
        next unless k.type == :sym
        case k.children[0]
        when :polymorphic then rec[:polymorphic] = (v.type == :true)
        when :class_name  then rec[:class_name] = v.children[0].to_s if %i[str sym].include?(v.type)
        when :as          then rec[:as] = v.children[0].to_s if v.type == :sym
        when :through     then rec[:through] = v.children[0].to_s if v.type == :sym
        end
      end
      rec
    end

    # Receiver / RHS summary — the joined record L0/L1 consume.
    #   {kind: :const, name: "User"}
    #   {kind: :chain, base: "User", methods: ["where", "first"]}
    #   {kind: :lvar/:ivar, name: "user", methods: [...]}   (var_chain folds here)
    #   {kind: :self} | {kind: :self_chain, methods: [...]} | nil (unknown)
    def summarize(node)
      return { kind: :self } if node.nil?
      return nil unless node.is_a?(Parser::AST::Node)
      case node.type
      when :const then { kind: :const, name: const_string(node) }
      when :lvar  then { kind: :lvar, name: node.children[0].to_s, methods: [] }
      when :ivar  then { kind: :ivar, name: node.children[0].to_s.delete_prefix('@'), methods: [] }
      when :self  then { kind: :self }
      when :send, :csend
        inner = summarize(node.children[0])
        m = node.children[1].to_s
        case inner&.dig(:kind)
        when :const
          { kind: :chain, base: inner[:name], methods: [m] }
        when :chain
          { kind: :chain, base: inner[:base], methods: inner[:methods] + [m] }
        when :lvar, :ivar
          { kind: inner[:kind], name: inner[:name], methods: inner[:methods] + [m] }
        when :self
          { kind: :self_chain, methods: [m] }
        when :self_chain
          { kind: :self_chain, methods: inner[:methods] + [m] }
        end
      when :block
        summarize(node.children[0])
      end
    end

    def const_string(node)
      return nil unless node.is_a?(Parser::AST::Node) && node.type == :const
      parent, name = node.children
      if parent.is_a?(Parser::AST::Node) && parent.type == :const
        "#{const_string(parent)}::#{name}"
      elsif parent.is_a?(Parser::AST::Node) && parent.type == :cbase
        name.to_s # ::User — treat as top level
      else
        name.to_s
      end
    end

    def split_const(name)
      (name || '').split('::')
    end
  end
end
