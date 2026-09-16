Class {
  #name : :tcp_socket,
  #superclass : [:object],
  #metaclass : :class,
  #ivars : [
    host: [],
    port: [],
    status: []
  ]
}

:tcp_socket >> :init, [self, args, self] [
  get_slots(args, %{host: host, port: port})
  set_slots(self, %{
    host: host,
    port: port,
    status: :disconnected
  })
]

:tcp_socket >> :connect, [self, effect] [
  get_slots(self, %{status: :disconnected, host: host, port: port})
  set_slot(self, :status, :connecting)
  emit_effect(:tcp, :connect, [self, host, port], effect)
]

:tcp_socket >> :connected, [self] [
  get(self, :status, :connecting)
  set_slot(self, :status, :connected)
]

:tcp_socket >> :connection_failed, [self, reason] [
  get(self, :status, :connecting)
  set_slot(self, :status, {:error, reason})
]

:tcp_socket >> :send_bytes, [self, data, effect] [
  get(self, :status, :connected)
  emit_effect(:tcp, :send, [self, data], effect)
]

:tcp_socket >> :close, [self, effect] [
  get(self, :status, :connected)
  set_slot(self, :status, :closing)
  emit_effect(:tcp, :close, [self], effect)
]

:tcp_socket >> :receive, [_self, {:data, _data}] [
]

:tcp_socket >> :connection_lost, [self, :closed] [
  set_slot(self, :status, :disconnected)
]

:tcp_socket >> :connection_lost, [self, reason] [
  set_slot(self, :status, {:error, reason})
]
