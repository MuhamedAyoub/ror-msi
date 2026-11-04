# ConventionOracleV2 — the L3 convention oracle (plan rules R1–R18).
#
# Reads Rails macros as typing judgments:
#   belongs_to :user             ==> method `user`  : User          (R1/R2)
#   has_many :order_items        ==> method `order_items` : Rel<OrderItem> (R3–R6)
#   has_many :comments, as: :p   ==> declarer of interface p        (R7)
#   belongs_to :p, polymorphic:  ==> type = union of declarers Δ(p) (R8)
#   scope / delegate / alias_method / define_method                 (R12–R15)
# and emits framework coupling edges (assoc weight 2, lookups/jobs/services 1).
require_relative 'InflectorV2'

module V2
  class ConventionOracleV2
    AR_INSTANCE_RET = %w[find find_by find_by! first last take sole create create! new build
                         find_or_create_by find_or_initialize_by].freeze
    AR_RELATION_RET = %w[where all includes joins left_joins eager_load preload references
                         group order having limit offset distinct unscoped readonly lock
                         select not merge].freeze
    AR_QUERY = (AR_INSTANCE_RET + AR_RELATION_RET +
                %w[pluck count exists? any? none? update update_all destroy_all delete_all]).freeze
    MAILER_DELIVERY = %w[deliver_now deliver_later deliver].freeze
    JOB_TRIGGER     = %w[perform_now perform_later set].freeze
    SERVICE_SUFFIX  = /Service$|Operation$|Command$|Query$|Worker$|Form$|Presenter$|Builder$/.freeze

    attr_reader :generated, :delta, :coupling_facts, :stats

    # corpus: {qualified_name => ClassFacts}; model_set: Set of qualified names
    def initialize(corpus, model_set)
      @corpus = corpus
      @models = model_set
      @generated = Hash.new { |h, k| h[k] = {} }  # cls => {method => {type:, target:, rule:}}
      @delta = Hash.new { |h, k| h[k] = [] }      # interface p => [declarer classes]
      @coupling_facts = []                        # {src:, dst:, kind:, weight:}
      @stats = Hash.new(0)
      build!
    end

    def generated_method(cls, name)
      @generated[cls][name]
    end

    private

    def build!
      # Pass 1 (R7): collect Δ(p) from every `as:` declaration.
      @corpus.each_value do |cf|
        cf.macros.each do |m|
          next unless %i[has_many has_one].include?(m[:kind]) && m[:as]
          @delta[m[:as]] << cf.qualified_name
        end
      end

      # Pass 2: generated methods + association edges.
      @corpus.each_value { |cf| interpret_class(cf) }

      # Pass 3: idiom edges from call records (R10/R11 lookups, R18 jobs etc.)
      @corpus.each_value { |cf| idiom_edges(cf) }
    end

    def interpret_class(cf)
      src = cf.qualified_name
      cf.macros.each do |m|
        case m[:kind]
        when :belongs_to, :has_one, :has_many, :has_and_belongs_to_many
          plural = %i[has_many has_and_belongs_to_many].include?(m[:kind])
          if m[:polymorphic]                                   # R8
            targets = @delta[m[:name]]
            if targets.empty?
              @stats[:polymorphic_unresolved] += 1
            else
              @stats[:polymorphic_resolved] += 1
              @generated[src][m[:name]] =
                { type: :instance_union, targets: targets, rule: 'R8' }
              targets.each do |t|
                @coupling_facts << { src: src, dst: t, kind: 'assoc:polymorphic', weight: 2 }
              end
            end
            next
          end
          target = m[:class_name] ||                            # R2
                   (plural ? Inflector.classify_plural(m[:name])
                           : Inflector.classify(m[:name]))      # R1/R3-R6
          resolved = resolve_in_corpus(target, cf.namespace)
          @generated[src][m[:name]] = {
            type: plural ? :relation : :instance,
            targets: [resolved || target], rule: 'R1-R6'
          }
          if resolved
            @coupling_facts << { src: src, dst: resolved, kind: "assoc:#{m[:kind]}", weight: 2 }
          else
            @stats[:assoc_target_missing] += 1
          end
        when :scope                                             # R12
          @generated[src][m[:name]] = { type: :relation, targets: [src], rule: 'R12', static: true }
        when :delegate                                          # R13
          m[:methods].each do |dm|
            @generated[src][dm] = { type: :delegated, via: m[:to], targets: [], rule: 'R13' }
          end
        when :alias                                             # R14
          @generated[src][m[:new]] = { type: :aliased, of: m[:old], targets: [], rule: 'R14' }
        when :define_method                                     # R15
          @generated[src][m[:name]] = { type: :defined, targets: [], rule: 'R15' }
        end
      end
    end

    def idiom_edges(cf)
      src = cf.qualified_name
      cf.calls.each do |c|
        recv = c[:recv]
        base = case recv&.dig(:kind)
               when :const then recv[:name]
               when :chain then recv[:base]
               end
        next unless base
        resolved = resolve_in_corpus(base, cf.namespace)
        next unless resolved && resolved != src

        if (MAILER_DELIVERY + JOB_TRIGGER).include?(c[:name]) ||
           %w[perform_now perform_later].any? { |t| recv[:kind] == :chain && recv[:methods]&.include?(t) }
          @coupling_facts << { src: src, dst: resolved, kind: 'mailer_or_job', weight: 1 } # R18
        elsif c[:name] == 'call' && resolved.match?(SERVICE_SUFFIX)
          @coupling_facts << { src: src, dst: resolved, kind: 'service_call', weight: 1 }  # R18
        elsif c[:name] == 'new' && resolved.match?(SERVICE_SUFFIX)
          @coupling_facts << { src: src, dst: resolved, kind: 'service_call', weight: 1 }  # R18
        elsif AR_QUERY.include?(c[:name]) && @models.include?(resolved)
          @coupling_facts << { src: src, dst: resolved, kind: 'model_lookup', weight: 1 }  # R10/R11
        end
      end
    end

    # Ruby-style constant lookup approximation: innermost namespace first.
    def resolve_in_corpus(name, namespace)
      return nil if name.nil? || name.empty?
      return name if @corpus.key?(name)
      (namespace.size - 1).downto(0) do |i|
        cand = (namespace[0..i] + [name]).join('::')
        return cand if @corpus.key?(cand)
      end
      nil
    end
  end
end
