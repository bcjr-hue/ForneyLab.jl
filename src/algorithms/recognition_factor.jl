export RecognitionFactor

"""
A `RecognitionFactor` specifies the subset of variables that comprise
a joint factor in the recognition factorization.
"""
mutable struct RecognitionFactor
    id::Symbol
    variables::Set{Variable}
    clusters::Set{Cluster}
    internal_edges::Set{Edge}

    # Fields for fast lookup during assembly
    interface_to_schedule_entry::Dict{Interface, ScheduleEntry}
    target_to_marginal_entry::Dict{Union{Variable, Cluster}, MarginalEntry}

    # Fields set by algorithm assembler
    schedule::Schedule
    marginal_table::MarginalTable
    optimize::Bool
    initialize::Bool

    function RecognitionFactor(algo=currentAlgorithm(); id=generateId(RecognitionFactor))
        # Constructor for empty container
        self = new(id)
        algo.recognition_factors[id] = self # Register self with recognition factorization

        return self
    end

    function RecognitionFactor(variables::Set{Variable}; algo=currentAlgorithm(), id=generateId(RecognitionFactor))
        # Determine nodes connected to external edges
        internal_edges = ForneyLab.extend(edges(variables))
        subgraph_nodes = nodes(internal_edges)
        external_edges = setdiff(edges(subgraph_nodes), internal_edges)
        nodes_connected_to_external_edges = intersect(nodes(external_edges), subgraph_nodes)
        
        # Determine variables required for variational updates
        internal_edges_connected_to_external_nodes = intersect(edges(nodes_connected_to_external_edges), internal_edges)
        recognition_variables = Set{Variable}([edge.variable for edge in internal_edges_connected_to_external_nodes])
        
        # Construct clusters required for (structured) variational updates
        recognition_clusters = Set{Cluster}()
        for node in nodes_connected_to_external_edges
            # Cluster edges must be ordered according to interfaces (therefore, intersect(edges(node), internal_edges) will not suffice)
            cluster_edges = Edge[]
            for interface in node.interfaces
                if interface.edge in internal_edges
                    push!(cluster_edges, interface.edge)
                end
            end

            if length(cluster_edges) > 1 # Constuct Cluster if multiple edges connected to node belong to the current subgraph
                push!(recognition_clusters, Cluster(node, cluster_edges))
            end
        end            

        # Create new recognition factor
        self = new(id, union(variables, recognition_variables), recognition_clusters, internal_edges)
        algo.recognition_factors[id] = self # Register self with recognition factorization

        # Register relevant edges with the recognition factorization for fast lookup during scheduling
        for edge in internal_edges_connected_to_external_nodes
            algo.edge_to_recognition_factor[edge] = self
        end

        # Register clusters with the recognition factorization for fast lookup during scheduling
        for cluster in recognition_clusters
            for edge in cluster.edges
                algo.node_edge_to_cluster[(cluster.node, edge)] = cluster
            end
        end 

        return self 
    end
end

RecognitionFactor(variable::Variable; id=generateId(RecognitionFactor)) = RecognitionFactor(Set([variable]), id=id)
RecognitionFactor(variables::Vector{Variable}; id=generateId(RecognitionFactor)) = RecognitionFactor(Set(variables), id=id)

function draw(rf::RecognitionFactor; schedule=ScheduleEntry[], args...)
    subgraph_nodes = nodes(rf.internal_edges)
    external_edges = setdiff(edges(subgraph_nodes), rf.internal_edges)
    ForneyLab.graphviz(ForneyLab.genDot(subgraph_nodes, rf.internal_edges, schedule=schedule, external_edges=external_edges); args...)
end

"""
Return whether the subgraph contains a collider. If a collider is found, this will lead to conditional dependencies in the recognition distribution (posterior).
"""
function hasCollider(rf::RecognitionFactor)
    stack = copy(rf.internal_edges)
    while !isempty(stack)
        # Choose a maximal connected cluster in the subgraph
        seed_edge = first(stack)
        connected_cluster = extend(seed_edge, terminate_at_soft_factors=false, limit_set=rf.internal_edges) # Extend the seed edge to find a maximal connected cluster within the subgraph

        if hasCollider(connected_cluster)
            # If one of the connected clusters has a collider, the subgraph has a collider
            return true
        end

        stack = setdiff(stack, connected_cluster)
    end

    return false
end

"""
Return whether connected_cluster contains a collider. This function assumes the graph for connected_cluster is a connected tree.
"""
function hasCollider(connected_cluster::Set{Edge})
    nodes_connected_to_external_edges = nodesConnectedToExternalEdges(connected_cluster)

    # A prior node is a node for which only the outbound edge is internal to the cluster.
    # It represents a prior belief over a single variable in the present subgraph.
    n_prior_nodes = 0
    for node in nodes_connected_to_external_edges
        if node.interfaces[1].edge in connected_cluster # Check if the outbound edge is internal to the subgraph
            # If so, check if there are no other edges internal to the subgraph
            prior_flag = true
            for iface in node.interfaces
                (iface == node.interfaces[1]) && continue
                if iface.edge in connected_cluster # There is another edge besides the outbound in the cluster
                    prior_flag = false
                    break
                end
            end
            prior_flag && (n_prior_nodes += 1) # If there is no other edge internal to the subgraph, the node is a prior node
        end

        # If the subgraph contains more than one prior node, the variables on the outbound
        # edges of these nodes are conditionally dependent in the recognition distibution (posterior)
        (n_prior_nodes > 1) && return true
    end

    return false
end

"""
Find the smallest legal subgraph that includes the argument edges. Default setting terminates the search at soft factors
and does not constrain the search to a limiting set (as specified by an empty `limit_set` argument).
"""
function extend(edge_set::Set{Edge}; terminate_at_soft_factors=true, limit_set=Set{Edge}())
    cluster = Set{Edge}() # Set to fill with edges in cluster
    edges = copy(edge_set)
    while !isempty(edges) # As long as there are unchecked edges connected through deterministic nodes
        current_edge = pop!(edges) # Pick one
        push!(cluster, current_edge) # Add to edge cluster
        
        connected_nodes = [] # Find nodes connected to edge (as a vector)
        (current_edge.a == nothing) || push!(connected_nodes, current_edge.a.node)
        (current_edge.b == nothing) || push!(connected_nodes, current_edge.b.node)

        for node in connected_nodes # Check both head and tail node (if present)
            if (terminate_at_soft_factors==false) || isa(node, DeltaFactor)
                for interface in node.interfaces
                    if (interface.edge !== current_edge) && !(interface.edge in cluster) && ( isempty(limit_set) || (interface.edge in limit_set) ) # Is next level edge not seen yet, and is it contained in the limiting set?
                        # Add unseen edges to the stack (to visit sometime in the future)
                        push!(edges, interface.edge)
                    end
                end
            end
        end
    end

    return cluster
end

extend(edge::Edge; terminate_at_soft_factors=true, limit_set=Set{Edge}()) = extend(Set{Edge}([edge]), terminate_at_soft_factors=terminate_at_soft_factors, limit_set=limit_set)

"""
Find the `RecognitionFactor` that `edge` belongs to (if available)
"""
function recognitionFactor(edge::Edge)
    dict = current_algorithm.edge_to_recognition_factor
    if haskey(dict, edge)
        rf = dict[edge]
    else # No recognition factor is found, return the edge itself
        rf = edge
    end

    return rf::Union{RecognitionFactor, Edge}
end

"""
Return the ids of the recognition factors to which edges connected to `node` belong
"""
localRecognitionFactors(node::FactorNode) = Any[recognitionFactor(interface.edge) for interface in node.interfaces]

"""
Find the nodes in `recognition_factor` that are connected to external edges
"""
nodesConnectedToExternalEdges(recognition_factor::RecognitionFactor) = nodesConnectedToExternalEdges(recognition_factor.internal_edges)

"""
Find the nodes connected to `internal_edges` that are also connected to external edges
"""
function nodesConnectedToExternalEdges(internal_edges::Set{Edge})
    subgraph_nodes = nodes(internal_edges)
    external_edges = setdiff(edges(subgraph_nodes), internal_edges)
    # nodes_connected_to_external_edges are the nodes connected to external edges that are also connected to internal edges
    nodes_connected_to_external_edges = intersect(nodes(external_edges), subgraph_nodes)

    return nodes_connected_to_external_edges
end

"""
Return a dictionary from recognition factor-id to variable/cluster-ids local to `node`
"""
function localRecognitionFactorization(node::FactorNode)
    # For each edge connected to node, collect the recognition factor and cluster id
    local_recognition_factors = localRecognitionFactors(node)
    local_clusters = localClusters(node)

    # Construct dictionary for local recognition factorization
    local_recognition_factorization = Dict{Union{RecognitionFactor, Edge}, Union{Cluster, Variable}}()
    for (idx, factor) in enumerate(local_recognition_factors)
        local_recognition_factorization[factor] = local_clusters[idx]
    end

    return local_recognition_factorization
end

function assembleAlgorithm!(rf::RecognitionFactor)
    # Generate structures for fast lookup
    rf.interface_to_schedule_entry = ForneyLab.interfaceToScheduleEntry(rf.schedule)
    rf.target_to_marginal_entry = ForneyLab.targetToMarginalEntry(rf.marginal_table)

    assembleSchedule!(rf)
    assembleInitialization!(rf)
    assembleMarginalTable!(rf)

    return rf
end

function assembleSchedule!(rf::RecognitionFactor)
    # Collect inbounds and assign message index per schedule entry
    for (msg_idx, schedule_entry) in enumerate(rf.schedule)
        schedule_entry.inbounds = collectInbounds(schedule_entry, schedule_entry.message_update_rule, rf.interface_to_schedule_entry, rf.target_to_marginal_entry)
        schedule_entry.schedule_index = msg_idx
    end

    return rf
end

function assembleInitialization!(rf::RecognitionFactor)
    # Collect outbound types from schedule
    outbound_types = Dict{Interface, Type}()
    for entry in rf.schedule
        outbound_types[entry.interface] = outboundType(entry.message_update_rule)
    end

    # Find breaker types and dimensions
    rf_update_clamp_flag = false # Flag that tracks whether the update of a clamped variable is required
    rf_initialize_flag = false # Indicate need for an initialization block
    for entry in rf.schedule
        partner = ultimatePartner(entry.interface)
        if (entry.message_update_rule <: ExpectationPropagationRule)
            breaker_entry = rf.interface_to_schedule_entry[partner]
            assembleBreaker!(breaker_entry, family(outbound_types[partner]), ()) # Univariate only
            rf_initialize_flag = true 
        elseif isa(entry.interface.node, Nonlinear) && (entry.interface == entry.interface.node.interfaces[2]) && (entry.interface.node.g_inv == nothing)
            # Set initialization in case of a nonlinear node without given inverse 
            iface = ultimatePartner(entry.interface.node.interfaces[2])
            breaker_entry = rf.interface_to_schedule_entry[iface]
            assembleBreaker!(breaker_entry, family(outbound_types[iface]), entry.interface.node.dims)
            rf_initialize_flag = true
        elseif !(partner == nothing) && isa(partner.node, Clamp)
            rf_update_clamp_flag = true # Signifies the need for creating a custom `step!` function for optimizing clamped variables
            iface = entry.interface
            breaker_entry = rf.interface_to_schedule_entry[iface]
            assembleBreaker!(breaker_entry, family(outbound_types[iface]), size(partner.node.value))
            rf_initialize_flag = true
        end
    end

    rf.optimize = rf_update_clamp_flag
    rf.initialize = rf_initialize_flag

    return rf
end

function assembleMarginalTable!(rf::RecognitionFactor)
    for entry in rf.marginal_table
        if entry.marginal_update_rule == Nothing
            iface = entry.interfaces[1]
            inbounds = [rf.interface_to_schedule_entry[iface]]
        elseif entry.marginal_update_rule == Product
            iface1 = entry.interfaces[1]
            iface2 = entry.interfaces[2]
            inbounds = [rf.interface_to_schedule_entry[iface1], 
                        rf.interface_to_schedule_entry[iface2]]
        else
            inbounds = collectInbounds(entry, rf.interface_to_schedule_entry, rf.target_to_marginal_entry)
        end

        entry.marginal_id = entry.target.id
        entry.inbounds = inbounds
    end

    return rf
end