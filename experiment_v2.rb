#!/usr/bin/env ruby
# experiment_v2.rb — parallel entry point for the v2 resolver pipeline.
#
# Identical CLI and JSON contract to experiment.rb, but the graph comes from
# tools/v2/RailsAwareGraphV2 (layered L0–L4 resolution + convention oracle)
# instead of tools/RailsAwareGraph (name+arity fan-out). experiment.rb is not
# modified; run both on the same app and diff the outputs.
#
# Usage: ruby experiment_v2.rb [alpha] [beta] [n_top] [classes_dir] [data_dir] \
#                              [output_json] [min_cluster_size] [gamma] \
#                              --rails-aware <app_root>
#
# Extra output field vs v1: "resolver_report" (per-layer resolution counters).
require_relative "tools/ClassNode"
require_relative "tools/MethodNode"
require_relative "tools/ClassTypeEnum"
require_relative "tools/helpers"
require_relative "tools/DependencyAnalyzer"
require_relative "tools/ClusterEngine"
require_relative "tools/Cluster"
require_relative "tools/v2/RailsAwareGraphV2"
require 'json'
require 'set'

alpha             = (ARGV[0] || 0.2).to_f
beta              = (ARGV[1] || 0.8).to_f
n_top             = (ARGV[2] || 8).to_i
classes_dir       = ARGV[3] || "./input/classes"
data_dir          = ARGV[4] || "./input/data"
output_file       = ARGV[5] || "./results/experiment_result_v2.json"
min_cluster_size  = (ARGV[6] || 3).to_i
gamma             = (ARGV[7] || 0.1).to_f

Dir.mkdir("./results") unless Dir.exist?("./results")
ENV['AST_OUTPUT_DIR'] = './results'

rails_idx = ARGV.index("--rails-aware")
rails_aware_root = rails_idx ? ARGV[rails_idx + 1] : nil
abort "[experiment_v2] --rails-aware <app_root> is required (v2 has no legacy mode)" unless rails_aware_root

$stderr.puts "[experiment_v2] alpha=#{alpha}, beta=#{beta}, n=#{n_top}, min_cs=#{min_cluster_size}, gamma=#{gamma}"
$stderr.puts "[experiment_v2] rails_aware_root=#{rails_aware_root.inspect}"

builder = V2::RailsAwareGraphV2.new(app_root: rails_aware_root).build!
classNodes = builder.class_nodes
dataNodes  = builder.data_nodes
dependencies = builder.dependency_analyzer
$stderr.puts "[experiment_v2] v2 graph: #{classNodes.size} classes, " \
             "#{builder.coverage[:total_edges]} total edges, " \
             "#{builder.coverage[:coupling_edges_landed]} coupling edges landed"
rr = builder.resolver_report
$stderr.puts "[experiment_v2] layers: " + rr.sort_by { |k, _| k.to_s }
                                            .map { |k, v| "#{k}=#{v}" }.join(", ")

# --- isolated-class filtering (same logic as experiment.rb) ---
isolated_classes = []
active_class_names = []
incoming = Set.new
dependencies.graph.each do |src, deps|
  deps.each_key { |dst| incoming << dst unless dst == src }
end
dependencies.graph.each do |class_name, deps|
  non_self_out = deps.reject { |k, _| k == class_name }
  if non_self_out.empty? && !incoming.include?(class_name)
    isolated_classes << class_name
  else
    active_class_names << class_name
  end
end
active_classNodes = classNodes.select { |cn| active_class_names.include?(cn.class_name) }

active_set = Set.new(active_class_names)
filtered_graph = Hash.new { |h, k| h[k] = {} }
filtered_data  = Hash.new { |h, k| h[k] = [] }
dependencies.graph.each do |src, edges|
  next unless active_set.include?(src)
  filtered_graph[src] = edges.select { |dst, _| active_set.include?(dst) }
end
active_class_names.each { |c| filtered_graph[c] }
dependencies.data.each do |src, ents|
  filtered_data[src] = ents if active_set.include?(src)
end
active_class_names.each { |c| filtered_data[c] }
filtered_dependencies = DependencyAnalyzer.allocate
filtered_dependencies.instance_variable_set(:@classNodes, active_classNodes)
filtered_dependencies.instance_variable_set(:@dataNodes, dataNodes)
filtered_dependencies.instance_variable_set(:@graph, filtered_graph)
filtered_dependencies.instance_variable_set(:@data, filtered_data)
filtered_dependencies.instance_variable_set(:@data_count, Hash.new { |h, k| h[k] = {} })

$stderr.puts "[experiment_v2] #{active_class_names.size} active classes, #{isolated_classes.size} isolated (excluded)"

# --- clustering (identical to experiment.rb default path) ---
msa = ClusterEngine.get_microservices(
  filtered_dependencies, alpha, beta, "./results/clusters_v2",
  n_top, min_cluster_size, gamma
)

# --- structured output (same contract + resolver_report) ---
graph_data = {}
filtered_dependencies.graph.each { |cn, deps| graph_data[cn] = deps.dup }
data_associations = {}
filtered_dependencies.data.each { |cn, ents| data_associations[cn] = ents.dup }
all_classes = filtered_dependencies.graph.keys

clusters = []
cluster_objects = []
if msa.is_a?(Array)
  msa.each_with_index do |cluster, idx|
    clusters << { "id" => idx + 1, "name" => cluster.name, "classes" => cluster.class_names }
    cluster_objects << cluster
  end
elsif msa.is_a?(Hash)
  idx = 0
  msa.each do |data_entity, class_list|
    idx += 1
    clusters << { "id" => idx, "name" => "MS_#{data_entity}", "classes" => class_list }
    cluster_objects << Cluster.new("MS_#{data_entity}", class_list)
  end
end

cluster_metrics = []
cluster_objects.each_with_index do |cluster, idx|
  ca = filtered_dependencies.get_intra_dependencies_of_ms(cluster)
  ce = 0
  cluster.class_names.each do |cn|
    next unless filtered_dependencies.graph[cn]
    filtered_dependencies.graph[cn].each do |target, count|
      ce += count unless cluster.class_names.include?(target)
    end
  end
  f_struct = ca.to_f / (ce + ca + 1.0e-10)
  f_data = filtered_dependencies.get_data_cohesion_of_ms(cluster)
  f_quality = alpha * f_struct + beta * f_data
  cluster_metrics << {
    "cluster_id" => idx + 1,
    "num_classes" => cluster.class_names.size,
    "intra_dependencies" => ca.round(4),
    "inter_dependencies" => ce.round(4),
    "f_struct" => f_struct.round(6),
    "f_data" => f_data.round(6),
    "f_quality" => f_quality.round(6)
  }
end

result = {
  "parameters" => {
    "alpha" => alpha, "beta" => beta, "n_top" => n_top,
    "min_cluster_size" => min_cluster_size, "gamma" => gamma,
    "mode" => alpha > 0.3 ? "hierarchical" : "data_cohesion",
    "resolver" => "v2",
    "classes_dir" => classes_dir, "data_dir" => data_dir
  },
  "summary" => {
    "total_classes_original" => classNodes.size,
    "total_classes_active" => all_classes.size,
    "isolated_classes" => isolated_classes.size,
    "total_data_entities" => dataNodes.size,
    "num_microservices" => clusters.size
  },
  "resolver_report" => builder.resolver_report,
  "dependency_graph" => graph_data,
  "data_associations" => data_associations,
  "clusters" => clusters,
  "cluster_metrics" => cluster_metrics,
  "isolated_classes" => isolated_classes
}

File.open(output_file, "w") { |f| f.write(JSON.pretty_generate(result)) }
$stderr.puts "[experiment_v2] Done. #{clusters.size} microservices identified → #{output_file}"
puts JSON.generate(result)
