Class {
  #name : :tcp_socket,
  #superclass : [:object],
  #metaclass : :class,
  #ivars : [
    host: [],
    port: [],
    packet: [default: :raw],
    owner: [default: :none],
    listener: [default: :none],
    inbox: [default: []],
    status: [default: :disconnected]
  ]
}

:tcp_socket >> :init, [self, args, self] [
  get_slots(args, %{host: _, port: _})
  call_next_method(self, args, self)
]

:tcp_socket >> :connect, [self, effect] [
  get_slots(self, %{status: :disconnected, host: host, port: port, packet: packet})
  set_slot(self, :status, :connecting)
  emit_effect(:tcp, :connect, [self, host, port, packet], effect)
]

:tcp_socket >> :listen, [self, effect] [
  get_slots(self, %{status: :disconnected, host: host, port: port, packet: packet})
  set_slot(self, :status, :starting)
  emit_effect(:tcp, :listen, [self, host, port, packet], effect)
]

:tcp_socket >> :connected, [self] [
  get(self, :status, :connecting)
  set_slot(self, :status, :connected)
]

:tcp_socket >> :connection_failed, [self, reason] [
  get(self, :status, :connecting)
  set_slot(self, :status, {:error, reason})
]

:tcp_socket >> :listening, [self, port] [
  get(self, :status, :starting)
  set_slots(self, %{port: port, status: :listening})
]

:tcp_socket >> :listen_failed, [self, reason] [
  set_slot(self, :status, {:error, reason})
]

:tcp_socket >> :send_bytes, [self, data, effect] [
  get(self, :status, :connected)
  emit_effect(:tcp, :send, [self, data], effect)
]

:tcp_socket >> :send_term, [self, term, effect] [
  encode_term(self, term, bytes)
  send_bytes(self, bytes, effect)
]

:tcp_socket >> :close, [self, effect] [
  get(self, :status, :connected)
  set_slot(self, :status, :closing)
  emit_effect(:tcp, :close, [self], effect)
]

:tcp_socket >> :close, [self, effect] [
  get(self, :status, :listening)
  set_slot(self, :status, :stopping)
  emit_effect(:tcp, :close_listener, [self], effect)
]

:tcp_socket >> :receive, [self, bytes] [
  get(self, :inbox, inbox)
  concat(inbox, [bytes], updated)
  set_slot(self, :inbox, updated)
]

:tcp_socket >> :accept, [self, peer, socket] [
  new_socket(self, peer, socket)
]

:tcp_socket >> :new_socket, [self, peer, socket] [
  get_slots(peer, %{address: host, port: port})
  get(self, :packet, packet)
  class(self, socket_class)

  new(
    socket_class,
    %{host: host, port: port, packet: packet, listener: self, status: :connected},
    socket
  )
]

:tcp_socket >> :accept_failed, [_self, _reason] [
]

:tcp_socket >> :connection_lost, [self, :closed] [
  set_slot(self, :status, :disconnected)
]

:tcp_socket >> :connection_lost, [self, reason] [
  set_slot(self, :status, {:error, reason})
]

:tcp_socket >> :stopped, [self] [
  set_slot(self, :status, :stopped)
]

:tcp_socket >> :stop_failed, [self, reason] [
  set_slot(self, :status, {:error, reason})
]

:tcp_socket >> :listener_lost, [self, reason] [
  set_slot(self, :status, {:error, reason})
]
