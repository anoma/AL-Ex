@tcp_socket
#{
  super: object,
  ivars: [
    #{name: host},
    #{name: port},
    #{default: raw, name: packet},
    #{default: none, name: owner},
    #{default: none, name: listener},
    #{default: [], name: inbox},
    #{default: disconnected, name: status}
  ]
}.

tcp_socket >> init
| Self Args Self |
get_slots Args #{host: _, port: _},
call_next_method Self Args Self.

tcp_socket >> connect
| Self Effect |
get_slots Self #{host: Host, packet: Packet, port: Port, status: disconnected},
set_slot Self status connecting,
new effect #{arguments: [Self, Host, Port, Packet], operation: connect, provider: tcp} Effect,
await Effect [Outcome] {connect_completed Self Outcome}.

tcp_socket >> listen
| Self Effect |
get_slots Self #{host: Host, packet: Packet, port: Port, status: disconnected},
set_slot Self status starting,
new effect #{arguments: [Self, Host, Port, Packet], operation: listen, provider: tcp} Effect,
await Effect [Outcome] {listen_completed Self Outcome}.

tcp_socket >> connect_completed
| Self #{status: ok, value: connected} |
connected Self.

tcp_socket >> connect_completed
| Self #{reason: Reason, status: error} |
connection_failed Self Reason.

tcp_socket >> listen_completed
| Self #{status: ok, value: Port} |
listening Self Port.

tcp_socket >> listen_completed
| Self #{reason: Reason, status: error} |
listen_failed Self Reason.

tcp_socket >> connected
| Self |
get Self status connecting,
set_slot Self status connected.

tcp_socket >> connection_failed
| Self Reason |
get Self status connecting,
set_slot Self status #{reason: Reason, status: error}.

tcp_socket >> listening
| Self Port |
get Self status starting,
set_slots Self #{port: Port, status: listening}.

tcp_socket >> listen_failed
| Self Reason |
set_slot Self status #{reason: Reason, status: error}.

tcp_socket >> send_bytes
| Self Data Effect |
get Self status connected,
new effect #{arguments: [Self, Data], operation: send, provider: tcp} Effect,
await Effect [Outcome] {send_completed Self Outcome}.

tcp_socket >> send_completed
| _Self #{status: ok, value: _Bytes} |.

tcp_socket >> send_completed
| Self #{reason: Reason, status: error} |
connection_lost Self Reason.

tcp_socket >> send_term
| Self Term Effect |
encode_term Self Term Bytes,
send_bytes Self Bytes Effect.

tcp_socket >> close
| Self Effect |
get Self status connected,
set_slot Self status closing,
new effect #{arguments: [Self], operation: close, provider: tcp} Effect,
await Effect [Outcome] {close_completed Self Outcome}.

tcp_socket >> close
| Self Effect |
get Self status listening,
set_slot Self status stopping,
new effect #{arguments: [Self], operation: close_listener, provider: tcp} Effect,
await Effect [Outcome] {close_listener_completed Self Outcome}.

tcp_socket >> close_completed
| Self #{status: ok, value: closed} |
connection_lost Self closed.

tcp_socket >> close_completed
| Self #{reason: Reason, status: error} |
connection_lost Self Reason.

tcp_socket >> close_listener_completed
| Self #{status: ok, value: stopped} |
stopped Self.

tcp_socket >> close_listener_completed
| Self #{reason: Reason, status: error} |
stop_failed Self Reason.

tcp_socket >> receive
| Self Bytes |
get Self inbox Inbox,
concat Inbox [Bytes] Updated,
set_slot Self inbox Updated.

tcp_socket >> accept
| Self Peer Socket |
new_socket Self Peer Socket.

tcp_socket >> new_socket
| Self Peer Socket |
get_slots Peer #{address: Host, port: Port},
get Self packet Packet,
class Self SocketClass,
new SocketClass #{host: Host, listener: Self, packet: Packet, port: Port, status: connected} Socket.

tcp_socket >> accept_failed
| _Self _Reason |.

tcp_socket >> connection_lost
| Self closed |
set_slot Self status disconnected.

tcp_socket >> connection_lost
| Self Reason |
set_slot Self status #{reason: Reason, status: error}.

tcp_socket >> stopped
| Self |
set_slot Self status stopped.

tcp_socket >> stop_failed
| Self Reason |
set_slot Self status #{reason: Reason, status: error}.

tcp_socket >> listener_lost
| Self Reason |
set_slot Self status #{reason: Reason, status: error}.