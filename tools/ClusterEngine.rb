class ClusterEngine


    def self.get_microservices(dependencies , alpha = 0.5 , beta = 0.5 , microservice_file = "./output/clusters" , n_top = 8, min_cluster_size = 3, gamma = 0.1)

      if (alpha > 0.3)
        dendro = self.herarchical_clusering(dependencies , alpha , beta)
        msa = self.identify_msa_condidates(dependencies , dendro , alpha , beta, gamma)

        # Phase 3: Merge tiny clusters
        msa = self.merge_small_clusters(dependencies, msa, min_cluster_size, alpha, beta)

        # Phase 2: Assign unassigned classes
        msa = self.assign_unassigned_classes(dependencies, msa)

        File.open(microservice_file + ".dot", "w") do |file|
          file.puts "digraph Microservices {"
          msa.each do |microservice|
            file.puts "  subgraph #{microservice.name}_microservice {"
            microservice.class_names.each do |class_name|
              file.puts "    #{class_name};"
            end
            file.puts "  }"
          end
          file.puts "}"
        end
        msa
      else
        msa_result = msa_condidate_with_data_cohesion(dependencies, n_top, microservice_file)

        # Convert hash result to Cluster array for post-processing
        cluster_objects = []
        if msa_result.is_a?(Hash)
          msa_result.each_with_index do |(data_entity, class_list), idx|
            cluster_objects << Cluster.new("MS_#{data_entity}", class_list)
          end
        else
          cluster_objects = msa_result
        end

        # Phase 3: Merge tiny clusters
        cluster_objects = self.merge_small_clusters(dependencies, cluster_objects, min_cluster_size, alpha, beta)

        # Phase 2: Assign unassigned classes
        cluster_objects = self.assign_unassigned_classes(dependencies, cluster_objects)

        cluster_objects
      end

    end

    # =========================================================================
    # Phase 1: Optimized Hierarchical Clustering — O(n²) instead of O(n³)
    # =========================================================================
    #
    # Strategy:
    #   1. Precompute pairwise merge-quality scores in an n×n matrix
    #   2. Cache intra-dependency counts and data sets per cluster
    #   3. On merge(A,B) → C: update only row/column C in O(n)
    #   4. Find best pair by scanning matrix in O(n) per step
    #
    # Total: O(n²) instead of O(n³)
    # =========================================================================

    def self.herarchical_clusering(dependencies, alpha, beta)
        artifacts = dependencies.graph.keys
        n = artifacts.size
        return [] if n == 0

        # --- Build adjacency matrix for fast lookups ---
        # dep_matrix[i][j] = number of calls from class i to class j
        idx_map = {}  # class_name -> integer index
        artifacts.each_with_index { |name, i| idx_map[name] = i }

        dep_matrix = Array.new(n) { Array.new(n, 0) }
        artifacts.each do |src|
          si = idx_map[src]
          dependencies.graph[src].each do |tgt, count|
            ti = idx_map[tgt]
            dep_matrix[si][ti] = count if ti
          end
        end

        # --- Initialize clusters ---
        # Each cluster is identified by an integer ID
        # We track: members (set of class indices), intra_deps count, data_set
        clusters = {}  # id -> { members: Set, intra: int, data_set: Set }
        active_ids = []

        artifacts.each_with_index do |class_name, i|
          data_set = Set.new(dependencies.data[class_name] || [])
          clusters[i] = {
            members: Set.new([i]),
            intra: 0,
            data_set: data_set,
            name: "Cluster#{i + 1}",
            class_names: [class_name]
          }
          active_ids << i
        end

        # --- Precompute cross-dependency counts between all initial pairs ---
        # cross[i][j] = calls from members of cluster i to members of cluster j (i != j)
        # Initially each cluster is a single class, so cross[i][j] = dep_matrix[i][j] + dep_matrix[j][i]
        cross = Hash.new(0)
        for i in 0...n
          for j in (i+1)...n
            c = dep_matrix[i][j] + dep_matrix[j][i]
            cross[[i, j]] = c if c > 0
          end
        end

        # --- Precompute merge quality for all pairs ---
        # quality_matrix[i][j] = quality score if we merge clusters i and j
        quality_matrix = {}
        active_ids.combination(2) do |i, j|
          quality_matrix[[i, j].sort] = compute_merge_quality(
            clusters[i], clusters[j], cross[[i, j].sort] || 0,
            dependencies, alpha, beta
          )
        end

        # --- Build dendrogram ---
        dendro = []
        # Save initial state: array of Cluster objects
        dendro << active_ids.map { |id| Cluster.new(clusters[id][:name], clusters[id][:class_names]) }

        next_id = n
        $stderr.puts "[HC] Starting with #{n} clusters" if n > 50

        while active_ids.size > 1
          # --- Find best pair in O(k) where k = active clusters ---
          best_key = nil
          best_score = -Float::INFINITY
          quality_matrix.each do |key, score|
            if score > best_score && active_ids.include?(key[0]) && active_ids.include?(key[1])
              best_score = score
              best_key = key
            end
          end

          break unless best_key  # safety

          id_a, id_b = best_key
          ca = clusters[id_a]
          cb = clusters[id_b]

          # --- Merge A + B into new cluster C ---
          new_members = ca[:members] | cb[:members]
          new_intra = ca[:intra] + cb[:intra] + (cross[[id_a, id_b].sort] || 0)
          new_data = ca[:data_set] | cb[:data_set]
          new_class_names = ca[:class_names] + cb[:class_names]

          new_id = next_id
          next_id += 1
          clusters[new_id] = {
            members: new_members,
            intra: new_intra,
            data_set: new_data,
            name: "Cluster#{new_id + 1}",
            class_names: new_class_names
          }

          # --- Update cross-dependencies: cross[new_id][x] = cross[a][x] + cross[b][x] ---
          active_ids.delete(id_a)
          active_ids.delete(id_b)

          # Compute cross-deps between new cluster and all remaining active clusters
          active_ids.each do |x|
            cx_a = cross[[id_a, x].sort] || 0
            cx_b = cross[[id_b, x].sort] || 0
            cx_new = cx_a + cx_b
            cross[[new_id, x].sort] = cx_new if cx_new > 0
          end

          # --- Update quality matrix: compute quality for (new_id, x) ---
          # Remove all entries involving id_a or id_b
          quality_matrix.delete_if { |key, _| key.include?(id_a) || key.include?(id_b) }

          active_ids.each do |x|
            quality_matrix[[new_id, x].sort] = compute_merge_quality(
              clusters[new_id], clusters[x], cross[[new_id, x].sort] || 0,
              dependencies, alpha, beta
            )
          end

          active_ids << new_id

          # Save dendrogram step
          dendro << active_ids.map { |id| Cluster.new(clusters[id][:name], clusters[id][:class_names]) }

          if n > 50 && active_ids.size % 50 == 0
            $stderr.puts "[HC] #{active_ids.size} clusters remaining..."
          end
        end

        $stderr.puts "[HC] Dendrogram complete: #{dendro.size} levels" if n > 50
        return dendro
    end

    # Compute quality of merging two clusters
    def self.compute_merge_quality(cluster_a, cluster_b, cross_deps, dependencies, alpha, beta)
      merged_members = cluster_a[:members] | cluster_b[:members]
      merged_intra = cluster_a[:intra] + cluster_b[:intra] + cross_deps
      n = merged_members.size
      possible = n * (n - 1)
      f_struct = possible > 0 ? merged_intra.to_f / possible : 0.0

      # Data cohesion: Jaccard of merged data sets
      union_size = (cluster_a[:data_set] | cluster_b[:data_set]).size
      inter_size = (cluster_a[:data_set] & cluster_b[:data_set]).size
      f_data = union_size > 0 ? inter_size.to_f / union_size : 0.0

      (alpha * f_struct) + (beta * f_data)
    end


    # =========================================================================
    # Dendrogram cutting with size penalty (Phase 5)
    # =========================================================================

    def self.identify_msa_condidates(dependencies, dendro, alpha, beta, gamma = 0.1)
      stack_clusters = []
      stack_clusters.push({
          index: dendro.length - 1,
          cluster: dendro[dendro.length - 1][0]
      })

      msa = []
      total_classes = dendro[0].size  # total number of classes

      while stack_clusters.size > 0
        cluster_parent = stack_clusters.pop

        if cluster_parent[:index] == 0 || cluster_parent[:cluster].class_names.length == 1
          msa << cluster_parent[:cluster]
        else
          child1, child2 = get_children_of_cluster(dendro, cluster_parent)

          if child1.nil? || child2.nil?
            msa << cluster_parent[:cluster]
            next
          end

          s_new_clusters = []
          s_new_clusters << child1[:cluster]
          s_new_clusters << child2[:cluster]
          s_old_clusters = []
          s_old_clusters << cluster_parent[:cluster]
          for i in 0..(stack_clusters.length-1)
              s_new_clusters << stack_clusters[i][:cluster]
              s_old_clusters << stack_clusters[i][:cluster]
          end

          # Quality with size penalty (Phase 5)
          q_child1 = get_score_quality_with_size_penalty(dependencies, s_new_clusters, child1[:cluster], alpha, beta, gamma, total_classes)
          q_child2 = get_score_quality_with_size_penalty(dependencies, s_new_clusters, child2[:cluster], alpha, beta, gamma, total_classes)
          q_parent = get_score_quality_with_size_penalty(dependencies, s_old_clusters, cluster_parent[:cluster], alpha, beta, gamma, total_classes)

          if (q_child1 + q_child2) / 2.0 >= q_parent
            stack_clusters.push(child1)
            stack_clusters.push(child2)
          else
            msa << cluster_parent[:cluster]
          end
        end
      end
      msa
    end

  # Quality function with size penalty (Phase 5)
  def self.get_score_quality_with_size_penalty(dependencies, clusters, cluster, alpha, beta, gamma, total_classes, min_size = 5, max_size = 20)
    base_score = get_score_quality_of_all_ms(dependencies, clusters, cluster, alpha, beta)

    n = cluster.class_names.size
    if n < min_size
      penalty = (min_size - n).to_f / total_classes
    elsif n > max_size
      penalty = (n - max_size).to_f / total_classes
    else
      penalty = 0.0
    end

    base_score - gamma * penalty
  end

  def self.get_score_quality_of_all_ms(dependencies , clusters , cluster ,alpha , beta)
    # FStruct = intradependencies(MS) / nbPossibleDependencies(MS) [Eq 3.1]
    # nbPossibleDependencies = n*(n-1) where n is number of classes in the cluster
    ca = dependencies.get_intra_dependencies_of_ms(cluster)
    n = cluster.class_names.size
    possible = n * (n - 1)
    f_struct = possible > 0 ? ca.to_f / possible : 0.0
    data_cohesion = dependencies.get_data_cohesion_of_ms(cluster)
    score = ( alpha * f_struct ) + (beta * data_cohesion)
    return score
  end

    def self.get_children_of_cluster(dendro , cluster_parent)
        children = []
        index  = cluster_parent[:index] - 1
        find = false
        while (index >= 0  && find == false )
          clusters = dendro[index]
          clusters.combination(2) do |child1, child2|
            if (child1.class_names + child2.class_names).sort == cluster_parent[:cluster].class_names.sort
              children = [{index: index ,  cluster: child1 } , {index: index , cluster: child2} ]
              find = true
              break
            end
          end
          index = index - 1
        end

        return children[0], children[1] if children.size == 2
        return nil, nil
      end

    def self.find_closest_pair(clusters , index , dependencies , alpha , beta)

        best_score = -Float::INFINITY
        best_clusters = nil
        clusters.combination(2) do |cluster1, cluster2|
        new_clusters = clusters.reject { |cluster| cluster == cluster1 || cluster == cluster2 }
        new_cluster = Cluster.new("Cluster#{index}" , cluster1.class_names + cluster2.class_names)
        new_clusters << new_cluster
        score = get_score_quality_of_all_ms(dependencies , new_clusters , new_cluster , alpha , beta)
        if score > best_score
            best_score = score
            best_clusters = [cluster1 , cluster2]
        end
        end
        best_clusters
    end

    # =========================================================================
    # Phase 2: Post-clustering assignment of unassigned classes
    # =========================================================================

    def self.assign_unassigned_classes(dependencies, clusters)
      all_classes = Set.new(dependencies.graph.keys)
      assigned_classes = Set.new
      clusters.each { |c| c.class_names.each { |cn| assigned_classes << cn } }

      unassigned = (all_classes - assigned_classes).to_a
      return clusters if unassigned.empty?

      $stderr.puts "[assign] #{unassigned.size} unassigned classes to assign to #{clusters.size} partitions"

      # Sort unassigned by total affinity (descending) so high-affinity classes get placed first
      unassigned_with_affinity = unassigned.map do |cls|
        total = 0
        clusters.each do |cluster|
          total += compute_affinity(cls, cluster, dependencies)
        end
        [cls, total]
      end
      unassigned_with_affinity.sort_by! { |_, aff| -aff }

      assigned_count = 0
      utility_classes = []

      unassigned_with_affinity.each do |cls, _|
        best_cluster = nil
        best_affinity = 0

        clusters.each do |cluster|
          affinity = compute_affinity(cls, cluster, dependencies)
          if affinity > best_affinity
            best_affinity = affinity
            best_cluster = cluster
          end
        end

        if best_cluster
          best_cluster.class_names << cls
          assigned_count += 1
        else
          utility_classes << cls
        end
      end

      # Create a utility partition for completely disconnected classes
      if utility_classes.size > 0
        clusters << Cluster.new("MS_Utility", utility_classes)
        $stderr.puts "[assign] #{utility_classes.size} disconnected classes → MS_Utility"
      end

      $stderr.puts "[assign] Assigned #{assigned_count} classes to existing partitions"
      clusters
    end

    def self.compute_affinity(class_name, cluster, dependencies)
      affinity = 0
      # Calls from class_name to classes in cluster
      if dependencies.graph[class_name]
        dependencies.graph[class_name].each do |target, count|
          affinity += count if cluster.class_names.include?(target)
        end
      end
      # Calls from classes in cluster to class_name
      cluster.class_names.each do |cn|
        if dependencies.graph[cn] && dependencies.graph[cn][class_name]
          affinity += dependencies.graph[cn][class_name]
        end
      end
      affinity
    end

    # =========================================================================
    # Phase 3: Merge small clusters
    # =========================================================================

    def self.merge_small_clusters(dependencies, clusters, min_size = 3, alpha = 0.5, beta = 0.5, max_size = 30)
      return clusters if clusters.size <= 1

      changed = true
      while changed
        changed = false
        small_clusters = clusters.select { |c| c.class_names.size < min_size }
        break if small_clusters.empty?

        # Sort: smallest first
        small_clusters.sort_by! { |c| c.class_names.size }

        small_clusters.each do |small|
          next unless clusters.include?(small)  # may have been merged already

          best_target = nil
          best_coupling = 0

          clusters.each do |other|
            next if other == small
            next if other.class_names.size + small.class_names.size > max_size

            coupling = compute_coupling(small, other, dependencies)
            if coupling > best_coupling
              best_coupling = coupling
              best_target = other
            end
          end

          if best_target
            best_target.class_names.concat(small.class_names)
            clusters.delete(small)
            changed = true
          end
        end
      end

      $stderr.puts "[merge] After merging: #{clusters.size} partitions, sizes: #{clusters.map { |c| c.class_names.size }.sort.reverse.join(', ')}"
      clusters
    end

    def self.compute_coupling(cluster_a, cluster_b, dependencies)
      coupling = 0
      cluster_a.class_names.each do |ca|
        next unless dependencies.graph[ca]
        dependencies.graph[ca].each do |target, count|
          coupling += count if cluster_b.class_names.include?(target)
        end
      end
      cluster_b.class_names.each do |cb|
        next unless dependencies.graph[cb]
        dependencies.graph[cb].each do |target, count|
          coupling += count if cluster_a.class_names.include?(target)
        end
      end
      coupling
    end

    # =========================================================================
    # Data-cohesion mode (unchanged logic, returns Cluster array now)
    # =========================================================================

    def self.msa_condidate_with_data_cohesion(depend , n = 8 , microservice_file = "./output/clusters")
        data_entity_counts = Hash.new(0)
        not_needed_data_entity = ["Color"]
        # Count occurrences of each data entity
        data_dependence = depend.data_count
        data_dependence.dup.each do |class_name, data_entities|
          data_entities.each do |data , count|
            if (!not_needed_data_entity.include?(data))
                data_entity_counts[data] += count
            end
          end
        end

        # Select top n most-used data entities
        top_data_entities = data_entity_counts.sort_by { |data_entity, count| -count }.take(n).to_h

        # Group classes by their most-referenced top data entity
        microservices = Hash.new { |hash, key| hash[key] = [] }
        data_dependence.each do |class_name, data_entity_count|
          most_used_data_entity =  ""
          score = 0 ;
          top_data_entities.each_key do |top_data|
            if (data_entity_count[top_data] && data_entity_count[top_data] > score )
              score = data_entity_count[top_data]
              most_used_data_entity = top_data
            end
          end
          if (most_used_data_entity != "" )
            microservices[most_used_data_entity] << class_name
          end

        end

        getClassesOfMs(depend,microservices, microservice_file)

        return microservices
      end

    def self.getClassesOfMs (depend , microservices ,  ms_classes_file = "./output/clusters")
        File.open(ms_classes_file + ".dot", "w") do |file|
          file.puts "digraph Microservices {"
          # Iterate over each key-value pair in the hash
          ms_num = 1
          microservices.each_key do |microservice|
            file.puts "  subgraph microservice_#{ms_num} {"
            ms_num = ms_num + 1
            class_dependeces = []
            microservices[microservice].each do |class_name|
              file.puts "    #{class_name};"
              depend.graph[class_name].each do |class_name_depend, count|
                if (!class_name_depend.include?("Controller") && !class_dependeces.include?(class_name_depend))
                  class_dependeces << class_name_depend
                end
              end
            end
            file.puts "  }"
          end
          file.puts "}"

        end

      end

end
