@peer
#{
  super => object,
  ivars => [
    #{name => name},
    #{default => "127.0.0.1", name => host},
    #{default => 0, name => port},
    #{default => none, name => listener},
    #{default => [], name => connections},
    #{default => [], name => messages},
    #{default => idle, name => status}
  ]
}.

peer >> init
| Self Args Self |
get Args peer_name Name,
call_next_method Self Args Self,
get_slots Self #{host => Host, port => Port},
new tcp_socket #{host => Host, owner => Self, packet => 4, port => Port} Listener,
configure_listener Self Listener,
set_slots Self #{listener => Listener, name => Name, status => starting},
listen Listener _.

peer >> configure_listener
| _Self Listener |
defmethod Listener listening [Socket, Port] {
  call_next_method Socket Port,
  get Socket owner Peer,
  listening Peer Socket Port
},
defmethod Listener accept [Socket, Address, Connection] {get Socket owner Peer, accepted Peer Socket Address Connection},
defmethod Listener accept_failed [Socket, Reason] {
  get Socket owner Peer,
  set_slot Peer status #{reason => Reason, status => error}
}.

peer >> configure_connection
| _Self Connection |
defmethod Connection receive [Socket, Bytes] {
  call_next_method Socket Bytes,
  decode_term Socket Bytes Message,
  get Socket owner Peer,
  receive Peer Socket Message
}.

peer >> configure_connection
| Self Socket Connection |
configure_connection Self Socket,
defmethod Socket connected [Socket] {
  call_next_method Socket,
  get Socket owner Peer,
  handshake Peer Socket Connection
},
defmethod Socket connection_failed [Socket, Reason] {
  call_next_method Socket Reason,
  set_slot Connection state #{reason => Reason, status => error}
}.

peer >> accepted
| Self Listener Address Socket |
get_slots Address #{address => Host, port => Port},
get Listener packet Packet,
new tcp_socket #{
  host => Host,
  listener => Listener,
  owner => Self,
  packet => Packet,
  port => Port,
  status => connected
} Socket,
configure_connection Self Socket,
add_connection Self Socket.

peer >> connect
| Self Remote Socket Connection |
get Remote listener Listener,
get_slots Listener #{host => Host, port => Port},
new tcp_socket #{host => Host, owner => Self, packet => 4, port => Port} Socket,
new peer_connection #{socket => Socket} Connection,
configure_connection Self Socket Connection,
add_connection Self Socket,
connect Socket _.

peer >> handshake
| Self Socket Connection |
set_slot Connection state connected,
connection_established Self Socket.

peer >> add_connection
| Self Socket |
get Self connections Connections,
concat Connections [Socket] Updated,
set_slot Self connections Updated.

peer >> send_message
| Self Socket Message Effect |
get Self connections Connections,
member Connections Socket,
send_term Socket Message Effect.

peer >> listening
| Self _Socket Port |
set_slots Self #{port => Port, status => listening}.

peer >> connection_established
| _Self _Socket |.

peer >> receive
| Self Socket Message |
get Self messages Messages,
concat Messages [[Socket, Message]] Updated,
set_slot Self messages Updated.

peer >> stop
| Self |
get Self listener Listener,
close Listener _,
get Self connections Connections,
forall (member Connections Socket) (close Socket _),
set_slot Self status stopping.