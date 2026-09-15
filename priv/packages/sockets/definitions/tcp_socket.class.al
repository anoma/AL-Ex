Class {
  #name : :tcp_socket,
  #superclass : [:object],
  #metaclass : :class,
  #ivars : [
    host: [],
    port: [],
    status: [],
    last_received: [],
    last_sent_bytes: [],
    last_error: [],
    effect_id: []
  ]
}

:tcp_socket >> :init, [self, args, self] [
  get_slots(args, %{host: host, port: port})
  set_slots(self, %{
    host: host,
    port: port,
    status: :disconnected,
    last_received: :none,
    last_sent_bytes: 0,
    last_error: :none,
    effect_id: :none
  })
]

:tcp_socket >> :connect, [self] [
  get_slots(self, %{status: :disconnected, host: host, port: port})
  set_slot(self, :status, :connecting)
  emit_effect(:tcp, :connect, [self, host, port], {self, :connected, []})
]

:tcp_socket >> :connected, [self, effect_id, {:ok, :connected}] [
  set_slots(self, %{effect_id: effect_id, status: :connected, last_error: :none})
]

:tcp_socket >> :connected, [self, effect_id, {:error, reason}] [
  set_slots(self, %{effect_id: effect_id, status: :error, last_error: reason})
]

:tcp_socket >> :read, [self] [
  get(self, :status, :connected)
  emit_effect(:tcp, :receive, [self], {self, :received, []})
]

:tcp_socket >> :received, [self, effect_id, {:ok, data}] [
  set_slots(self, %{effect_id: effect_id, last_received: data, last_error: :none})
]

:tcp_socket >> :received, [self, effect_id, {:error, reason}] [
  set_slots(self, %{effect_id: effect_id, status: :error, last_error: reason})
]

:tcp_socket >> :write, [self, data] [
  get(self, :status, :connected)
  emit_effect(:tcp, :send, [self, data], {self, :sent, []})
]

:tcp_socket >> :sent, [self, effect_id, {:ok, bytes}] [
  set_slots(self, %{effect_id: effect_id, last_sent_bytes: bytes, last_error: :none})
]

:tcp_socket >> :sent, [self, effect_id, {:error, reason}] [
  set_slots(self, %{effect_id: effect_id, status: :error, last_error: reason})
]

:tcp_socket >> :close, [self] [
  get(self, :status, :connected)
  set_slot(self, :status, :closing)
  emit_effect(:tcp, :close, [self], {self, :closed, []})
]

:tcp_socket >> :closed, [self, effect_id, {:ok, :closed}] [
  set_slots(self, %{effect_id: effect_id, status: :disconnected, last_error: :none})
]

:tcp_socket >> :closed, [self, effect_id, {:error, reason}] [
  set_slots(self, %{effect_id: effect_id, status: :error, last_error: reason})
]
