export Interface
export clearMessage!, setMessage!, message, handle

"""
An Interface belongs to a node and is used to send/receive messages.
An Interface can be seen as a half-edge; it has exactly one partner interface, with wich it forms an edge.
A message from node a to node b is stored at the Interface of node a that connects to an Interface of node b.
"""
type Interface
    node::Node
    edge::Union{AbstractEdge, Void}
    partner::Union{Interface, Void}
    message::Union{Message, Void}
end
Interface(node::Node) = Interface(node, nothing, nothing, nothing)

function show(io::IO, interface::Interface)
    iface_handle = handle(interface)
    (iface_handle == "") || (iface_handle = "($(iface_handle))")
    println(io, "Interface $(findfirst(interface.node.interfaces, interface)) $(iface_handle) of $(typeof(interface.node)) $(interface.node.id)")
end

==(interface1::Interface, interface2::Interface) = is(interface1, interface2)

Base.deepcopy(::Interface) = error("deepcopy(::Interface) is not possible. An Interface should only be created by a Node constructor.")

function setMessage!(interface::Interface, message::Message)
    interface.message = deepcopy(message)
end

clearMessage!(interface::Interface) = (interface.message = nothing)

function handle(interface::Interface)
    # Return named interface handle
    if isdefined(interface.node, :i)
        for h in keys(interface.node.i)
            if (typeof(h)==Symbol || typeof(h)==Int) && is(interface.node.i[h], interface)
                return string(h)
            end
        end
    end

    return ""
end

function ensureMessage!{T<:ProbabilityDistribution}(interface::Interface, payload_type::Type{T})
    # Ensure that interface carries a Message{payload_type}, used for in place updates
    if interface.message == nothing || typeof(interface.message.payload) != payload_type
        if payload_type <: Delta{Float64}
            interface.message = Message(Delta())
        elseif payload_type <: Delta{Bool}
            interface.message = Message(Delta(false))
        elseif payload_type <: MvDelta
            interface.message = Message(MvDelta(zeros(dimensions(payload_type))))
        elseif payload_type <: MatrixDelta
            interface.message = Message(MatrixDelta(zeros(dimensions(payload_type)...)))
        else
            interface.message = Message(vague(payload_type))
        end
    end

    return interface.message
end
