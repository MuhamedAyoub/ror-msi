# ResolverV2 — the L0–L4 resolution cascade (plan §layers).
#
#   L0 syntactic     : constant receiver, namespace-aware        -> exact edge
#   L1 assignment    : var/ivar typed from `x = User.find(...)`  -> exact edge
#   L2 self + CHA    : own defs / superclass chain / mixins      -> internal or edge
#   L3 oracle+naming : convention-generated methods; R16/R17     -> tagged edge
#   L4 residue       : guarded fan-out, capped K, weight 1/|own| -> bounded noise
#
# Every resolution increments a layer counter; the report is the per-layer
# table the paper needs and the audit trail for old-vs-new comparison.
require_relative 'InflectorV2'
require_relative 'ConventionOracleV2'

module V2
  class ResolverV2
    # v1 baseline noise list (kept identical for comparability) ...
    BASE_NOISE = %w[
      send new initialize find save update delete destroy join split sort
      length size count get set include is_a respond_to? to_s to_sym to_i
      each map select reject inject reduce tap then yield_self present?
      blank? nil? empty? any? all? none? first last try class is_a?
    ].to_set.freeze
    # ... extended Rails homonyms filtered ONLY in the unresolved L4 path.
    L4_EXTRA_NOISE = %w[
      perform call execute run process handle build render valid? to_h to_json
      attributes errors persisted? id
    ].to_set.freeze
    FANOUT_CAP = 5

    attr_reader :graph, :report

    def initialize(corpus, oracle, model_set)
      @corpus = corpus          # {qualified_name => ClassFacts}
      @oracle = oracle
      @models = model_set
      @graph = Hash.new { |h, k| h[k] = Hash.new(0) }
      @report = Hash.new(0)
      build_method_owners!
      build_var_types!
    end

    def resolve_all!
      @corpus.each_value do |cf|
        cf.calls.each { |c| resolve_call(cf, c) }
      end
      @graph
    end

    private

    # ---------- indexes ----------

    def build_method_owners!
      @owners = Hash.new { |h, k| h[k] = [] }
      @corpus.each_value do |cf|
        cf.defs.each do |d|
          @owners[d[:name]] << { cls: cf.qualified_name, min: d[:min], max: d[:max] }
        end
        @oracle.generated[cf.qualified_name].each_key do |m|
          @owners[m] << { cls: cf.qualified_name, min: 0, max: INF }
        end
      end
    end

    # Two-pass, flow-insensitive var typing (L1).
    # Pass 1: rhs based on a constant (User.find -> instance User).
    # Pass 2: rhs based on a var typed in pass 1, incl. association readers
    #         (u = comment.user via oracle-generated types).
    def build_var_types!
      @var_types = Hash.new { |h, k| h[k] = {} } # [cls, scope] -> {var => type}
      2.times do |pass|
        @corpus.each_value do |cf|
          cf.assigns.each do |a|
            t = type_of(cf, a[:rhs], a[:scope])
            next unless t
            key = [cf.qualified_name, a[:scope] == :ivar ? :ivar : a[:scope]]
            @var_types[key][a[:var]] ||= t
          end
        end
      end
    end

    # type descriptor: {kind: :instance | :relation | :class, cls: "User"}
    #                | {kind: :union, classes: [..]}
    def type_of(cf, summary, scope = nil)
      return nil unless summary
      case summary[:kind]
      when :const
        c = resolve_const(summary[:name], cf)
        c ? { kind: :class, cls: c } : nil
      when :chain
        base = resolve_const(summary[:base], cf)
        return nil unless base
        apply_chain({ kind: :class, cls: base }, summary[:methods])
      when :lvar, :ivar
        base = lookup_var(cf, summary[:kind] == :ivar ? :ivar : scope, summary[:name])
        base && summary[:methods].any? ? apply_chain(base, summary[:methods]) : base
      end
    end

    def apply_chain(t, methods)
      methods.each do |m|
        return nil if t.nil?
        t = step_type(t, m)
      end
      t
    end

    def step_type(t, m)
      case t[:kind]
      when :class
        if ConventionOracleV2::AR_INSTANCE_RET.include?(m) then { kind: :instance, cls: t[:cls] }
        elsif ConventionOracleV2::AR_RELATION_RET.include?(m) then { kind: :relation, cls: t[:cls] }
        elsif (g = @oracle.generated_method(t[:cls], m)) && g[:type] == :relation
          { kind: :relation, cls: t[:cls] } # scope (R12)
        end
      when :relation
        if %w[first last take sole find find_by].include?(m) then { kind: :instance, cls: t[:cls] }
        elsif ConventionOracleV2::AR_RELATION_RET.include?(m) then t
        end
      when :instance
        g = @oracle.generated_method(t[:cls], m)
        return nil unless g
        case g[:type]
        when :instance then { kind: :instance, cls: g[:targets].first }
        when :relation then { kind: :relation, cls: g[:targets].first }
        when :instance_union then { kind: :union, classes: g[:targets] }
        end
      end
    end

    def lookup_var(cf, scope, name)
      @var_types[[cf.qualified_name, scope]][name] ||
        @var_types[[cf.qualified_name, :ivar]][name]
    end

    # ---------- the cascade ----------

    def resolve_call(cf, call)
      m = call[:name]
      return bump(:noise_filtered) if BASE_NOISE.include?(m) && !important_idiom?(call)
      src = cf.qualified_name
      recv = call[:recv]

      case recv&.dig(:kind)
      when :const                                      # ----- L0
        target = resolve_const(recv[:name], cf)
        return target && target != src ? edge(src, target, 1, :l0_const) : bump(:l0_internal_or_external)
      when :chain                                      # ----- L0 (chained on const)
        target = resolve_const(recv[:base], cf)
        return bump(:l0_internal_or_external) unless target
        # typed continuation: User.where(...).first.notify -> still User
        t = type_of(cf, recv)
        if t && (c = concrete(t)) && c != src
          return edge(src, c, 1, :l0_chain_typed)
        end
        return target == src ? bump(:l0_internal_or_external) : edge(src, target, 1, :l0_chain_base)
      when :lvar, :ivar                                # ----- L1 / L3-naming
        scope = recv[:kind] == :ivar ? :ivar : call[:in_method]
        t = lookup_var(cf, scope, recv[:name])
        t = apply_chain(t, recv[:methods]) if t && recv[:methods].any?
        if t
          case t[:kind]
          when :union                                  # polymorphic receiver (R8)
            t[:classes].each { |c| edge(src, c, 1.0 / t[:classes].size, :l1_union) unless c == src }
            return
          else
            c = concrete(t)
            if c && c != src && responds?(c, m, call[:num_args])
              edge(src, c, 1, :l1_var_typed)
              # R8: reading a polymorphic association couples the caller to
              # the interface's declarer set — fractional union edges.
              g = @oracle.generated_method(c, m)
              if g && g[:type] == :instance_union
                g[:targets].each do |u|
                  edge(src, u, 1.0 / g[:targets].size, :l1_union, count_once: true) unless u == src
                end
                bump(:l1_union)
              end
              return true
            end
            return bump(:l1_typed_no_method) if c
          end
        end
        return l3_naming(cf, recv[:name], call) || l4_residue(cf, call)
      when :self                                       # ----- L2
        owner = defining_ancestor(src, m, call[:num_args])
        if owner
          return owner == src ? bump(:l2_self_internal) : edge(src, owner, 1, :l2_mixin)
        end
        return bump(:l2_self_unknown)                  # inherited from framework — no guess
      when :self_chain                                 # result of a self method: unknown type
        return l4_residue(cf, call)
      else                                             # ----- L4
        return l4_residue(cf, call)
      end
    end

    def l3_naming(cf, var, call)
      name = var.delete_prefix('current_')             # R17
      cand = Inflector.classify(Inflector.singularize(name)) # R16
      target = resolve_const(cand, cf)
      return nil unless target && target != cf.qualified_name
      return nil unless responds?(target, call[:name], call[:num_args])
      edge(cf.qualified_name, target, 1, :l3_naming)
      true
    end

    def l4_residue(cf, call)
      m = call[:name]
      return bump(:l4_noise_suppressed) if L4_EXTRA_NOISE.include?(m)
      owners = (@owners[m] || []).select do |o|
        o[:cls] != cf.qualified_name && arity_ok?(o, call[:num_args])
      end
      return bump(:l4_no_owner) if owners.empty?
      return bump(:l4_cap_suppressed) if owners.size > FANOUT_CAP
      w = 1.0 / owners.size
      owners.each { |o| edge(cf.qualified_name, o[:cls], w, :l4_fanout, count_once: true) }
      bump(:l4_fanout_sites)
    end

    # ---------- helpers ----------

    def important_idiom?(call)
      # `find`/`new` on a constant are typed lookups (R10), not noise.
      %i[const chain].include?(call.dig(:recv, :kind))
    end

    def concrete(t)
      t && %i[instance relation class].include?(t[:kind]) ? t[:cls] : nil
    end

    def responds?(cls, m, nargs)
      !!defining_ancestor(cls, m, nargs)
    end

    def defining_ancestor(cls, m, nargs, seen = Set.new)
      return nil if cls.nil? || seen.include?(cls)
      seen << cls
      cf = @corpus[cls]
      return nil unless cf
      if cf.defs.any? { |d| d[:name] == m && arity_ok?(d, nargs) } ||
         @oracle.generated_method(cls, m)
        return cls
      end
      ancestors = [cf.superclass, *cf.mixins].compact
      ancestors.each do |a|
        r = resolve_const(a, cf)
        found = defining_ancestor(r, m, nargs, seen)
        return found if found
      end
      nil
    end

    def arity_ok?(d, n)
      n >= (d[:min] || 0) && n <= (d[:max] || INF)
    end

    def resolve_const(name, cf)
      return nil if name.nil? || name.empty?
      return name if @corpus.key?(name)
      ns = cf.namespace + [cf.qualified_name.split('::').last]
      (ns.size - 1).downto(0) do |i|
        cand = (ns[0..i] + [name]).join('::')
        return cand if @corpus.key?(cand)
      end
      # unique basename fallback
      @basenames ||= @corpus.keys.group_by { |k| k.split('::').last }
      hits = @basenames[name]
      hits && hits.size == 1 ? hits.first : nil
    end

    def edge(src, dst, w, layer, count_once: false)
      @graph[src][dst] += w
      bump(layer) unless count_once
      true
    end

    def bump(key)
      @report[key] += 1
      nil
    end
  end
end
