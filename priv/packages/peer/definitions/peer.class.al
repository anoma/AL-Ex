Class {
  #name : :peer,
  #superclass : [:object],
  #metaclass : :class,
  #ivars : [
    name: [],
    host: [default: "127.0.0.1"],
    port: [default: 0],
    listener: [default: :none],
    connections: [default: []],
    messages: [default: []],
    status: [default: :idle]
  ]
}

:peer >> :init, [self, args, self] [
  get(args, :peer_name, name)
  call_next_method(self, args, self)
  get_slots(self, %{host: host, port: port})
  new(:tcp_socket, %{host: host, port: port, owner: self}, listener)
  configure_listener(self, listener)
  set_slots(self, %{name: name, listener: listener, status: :starting})
  listen(listener, _)
]

:peer >> :configure_listener, [_self, listener] [
  defmethod(listener, :listening, [socket, port]) do
    call_next_method(socket, port)
    get(socket, :owner, peer)
    listening(peer, socket, port)
  end

  defmethod(listener, :accept, [socket, address, connection]) do
    get(socket, :owner, peer)
    accepted(peer, socket, address, connection)
  end

  defmethod(listener, :accept_failed, [socket, reason]) do
    get(socket, :owner, peer)
    set_slot(peer, :status, {:error, reason})
  end
]

:peer >> :configure_connection, [_self, connection] [
  defmethod(connection, :connected, [socket]) do
    call_next_method(socket)
    get(socket, :owner, peer)
    connection_established(peer, socket)
  end

  defmethod(connection, :receive, [socket, bytes]) do
    call_next_method(socket, bytes)
    get(socket, :owner, peer)
    receive(peer, socket, bytes)
  end
]

:peer >> :accepted, [self, listener, address, socket] [
  get_slots(address, %{address: host, port: port})

  new(
    :tcp_socket,
    %{host: host, port: port, owner: self, listener: listener, status: :connected},
    socket
  )

  configure_connection(self, socket)
  add_connection(self, socket)
]

:peer >> :connect, [self, remote, socket, effect] [
  get(remote, :listener, listener)
  get_slots(listener, %{host: host, port: port})
  new(:tcp_socket, %{host: host, port: port, owner: self}, socket)
  configure_connection(self, socket)
  add_connection(self, socket)
  connect(socket, effect)
]

:peer >> :add_connection, [self, socket] [
  get(self, :connections, connections)
  concat(connections, [socket], updated)
  set_slot(self, :connections, updated)
]

:peer >> :send_message, [self, socket, message, effect] [
  get(self, :connections, connections)
  member(connections, socket)
  send_bytes(socket, message, effect)
]

:peer >> :listening, [self, _socket, port] [
  set_slots(self, %{port: port, status: :listening})
]

:peer >> :connection_established, [_self, _socket] [
]

:peer >> :receive, [self, socket, message] [
  get(self, :messages, messages)
  concat(messages, [[socket, message]], updated)
  set_slot(self, :messages, updated)
]

:peer >> :stop, [self] [
  get(self, :listener, listener)
  close(listener, _)
  get(self, :connections, connections)

  forall([member(connections, socket)]) do
    close(socket, _)
  end

  set_slot(self, :status, :stopping)
]
