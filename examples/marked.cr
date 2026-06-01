require "../src/vow"

# `Vow::Exportable::Marked` lets a downstream framework keep its OWN export
# annotation and still reuse Vow's dispatch generation — Vow never learns about
# the annotation. This is the seam a higher-level framework builds on: it
# defines its own marker (with whatever sidecar fields it wants — routing, async
# scheduling, auth scopes) and hands that marker to `vow_register_marked`, which
# registers every method carrying it with the exact decode -> invoke ->
# JSON-encode callback Vow generates for `@[Vow::Export]`.

# A consumer-defined annotation. Vow knows nothing about it; it could carry any
# fields the framework cares about.
annotation Rpc; end

class ChatService
  include Vow::Exportable::Marked

  @[Rpc]
  def greet(name : String) : String
    "Hi, #{name}"
  end

  # Defaults are honored, and multi-word parameter names camelCase on the wire
  # (`room_id` -> `roomId`) — identical to `@[Vow::Export]`.
  @[Rpc]
  def join(user : String, room_id : Int32 = 1) : String
    "#{user} joined room #{room_id}"
  end

  # No marker -> never registered, stays private to Crystal.
  def secret : String
    "nope"
  end

  # The framework drives Vow's generation from one of its own instance methods,
  # passing its own marker. The macro expands in THIS class's context, so Vow
  # sees the marked methods without ever referencing `Rpc` itself.
  def install(registry : Vow::Registry) : Nil
    vow_register_marked(registry, Rpc)
  end
end

registry = Vow::Registry.new
ChatService.new.install(registry)

puts "registered: #{registry.names.sort}"
# => registered: ["ChatService.greet", "ChatService.join"]

puts registry.dispatch("ChatService.greet", %({"name": "Ada"}))           # "Hi, Ada"
puts registry.dispatch("ChatService.join", %({"user": "Ada"}))            # "Ada joined room 1" (default)
puts registry.dispatch("ChatService.join", %({"user": "Ada", "roomId": 7})) # "Ada joined room 7"
puts registry.includes?("ChatService.secret")                            # false (unmarked)
