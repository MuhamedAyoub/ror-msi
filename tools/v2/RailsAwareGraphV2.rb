# RailsAwareGraphV2 — v2 graph builder. Same public surface as
# tools/RailsAwareGraph.rb (class_nodes / data_nodes / dependency_analyzer /
# coverage / graph / data) so experiment_v2.rb and the Python pipeline can
# consume either builder's output interchangeably. The old builder is not
# touched; this is the parallel pipe for old-vs-new evaluation.
require 'json'
require 'set'

require_relative '../ClassNode'
require_relative '../ClassTypeEnum'
require_relative '../MethodNode'
require_relative '../DependencyAnalyzer'
require_relative 'InflectorV2'
require_relative 'AstFactsV2'
require_relative 'ConventionOracleV2'
require_relative 'ResolverV2'

module V2
  class RailsAwareGraphV2
    RAILS_CLASS_DIRS = %w[
      models controllers helpers mailers jobs policies workflows
      services builders presenters validators uploaders finders
      actions channels listeners dispatchers drops fields mailboxes
      dashboards lib classes data
    ].freeze

    attr_reader :class_nodes, :data_nodes, :graph, :data, :coverage, :resolver_report

    def initialize(app_root:, class_dirs: nil, ignore_patterns: [%r{/spec/}, %r{/test/}])
      @app_root = app_root
      @class_dirs = class_dirs || RAILS_CLASS_DIRS
      @ignore_patterns = ignore_patterns
      @corpus = {}          # qualified_name => ClassFacts
      @class_nodes = []
      @data_nodes = []
      @data = Hash.new { |h, k| h[k] = [] }
      @coverage = {}
      @resolver_report = {}
    end

    def build!
      parse_all!
      model_set = Set.new(@corpus.values.select { |c| %w[models data].include?(c.role) }
                                        .map(&:qualified_name))
      @oracle = ConventionOracleV2.new(@corpus, model_set)
      resolver = ResolverV2.new(@corpus, @oracle, model_set)
      @graph = resolver.resolve_all!

      apply_coupling_edges!
      build_class_nodes!(model_set)
      record_coverage!(resolver)
      self
    end

    # DependencyAnalyzer drop-in, same trick as v1 (allocate, no rebuild).
    def dependency_analyzer
      @dep_analyzer ||= begin
        da = DependencyAnalyzer.allocate
        da.instance_variable_set(:@classNodes, @class_nodes)
        da.instance_variable_set(:@dataNodes, @data_nodes)
        da.instance_variable_set(:@graph, @graph)
        da.instance_variable_set(:@data, @data)
        da.instance_variable_set(:@data_count, Hash.new { |h, k| h[k] = {} })
        da
      end
    end

    def classNodes = @class_nodes
    def dataNodes  = @data_nodes

    def to_dependency_graph_json
      @graph.transform_values(&:dup)
    end

    private

    def parse_all!
      @class_dirs.each do |sub|
        dir = File.join(@app_root, sub)
        next unless Dir.exist?(dir)
        Dir.glob(File.join(dir, '**/*.rb')).sort.each do |f|
          next unless File.file?(f)
          next if @ignore_patterns.any? { |p| f.match?(p) }
          AstFactsV2.parse_file(f, sub).each do |cf|
            # first definition wins; reopened classes merge their facts
            if (existing = @corpus[cf.qualified_name])
              existing.defs.concat(cf.defs)
              existing.calls.concat(cf.calls)
              existing.macros.concat(cf.macros)
              existing.assigns.concat(cf.assigns)
              existing.mixins.concat(cf.mixins)
            else
              @corpus[cf.qualified_name] = cf
            end
          end
        end
      end
    end

    def apply_coupling_edges!
      landed = 0
      @oracle.coupling_facts.each do |fact|
        next unless @corpus.key?(fact[:dst]) && fact[:src] != fact[:dst]
        @graph[fact[:src]][fact[:dst]] += fact[:weight]
        landed += 1
        if fact[:kind].start_with?('assoc') || fact[:kind] == 'model_lookup'
          @data[fact[:src]] << fact[:dst] unless @data[fact[:src]].include?(fact[:dst])
        end
      end
      @coupling_landed = landed
    end

    def build_class_nodes!(model_set)
      @corpus.each_value do |cf|
        methods_list = cf.defs.map { |d| { name: d[:name], num_args: d[:min] } }
        called = Hash.new { |h, k| h[k] = [] }
        cf.calls.each do |c|
          called[c[:in_method] || ''] << { name: c[:name], num_args: c[:num_args] }
        end
        type = model_set.include?(cf.qualified_name) ? ClassType::DataEntity
                                                     : ClassType::ClassController
        node = ClassNode.new(cf.qualified_name, cf.namespace.join('::'),
                             type, methods_list, @data[cf.qualified_name], called)
        @class_nodes << node
        if model_set.include?(cf.qualified_name)
          @data_nodes << ClassNode.new(cf.qualified_name, cf.namespace.join('::'),
                                       ClassType::DataEntity, [], [], [])
        end
        @graph[cf.qualified_name] # materialize empty rows
      end
    end

    def record_coverage!(resolver)
      @resolver_report = resolver.report.dup
      @resolver_report.merge!(@oracle.stats)
      @coverage = {
        total_files_ingested: @corpus.values.map(&:file).uniq.size,
        unique_classes: @corpus.size,
        classes_with_outgoing: @graph.count { |_, v| !v.empty? },
        total_edges: @graph.values.sum(&:size),
        coupling_edges_added: @oracle.coupling_facts.size,
        coupling_edges_landed: @coupling_landed,
        by_subdir: @corpus.values.group_by(&:role).transform_values(&:size),
        resolver_report: @resolver_report,
      }
    end
  end
end
