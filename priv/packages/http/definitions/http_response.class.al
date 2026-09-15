Class {
  #name : :http_response,
  #superclass : [:object],
  #metaclass : :class,
  #ivars : [
    state: [],
    status_code: [],
    headers: [],
    body: [],
    error: [],
    effect_id: []
  ]
}

:http_response >> :init, [self, args, self] [
  set_slots(self, %{
    state: :pending,
    status_code: :none,
    headers: [],
    body: :none,
    error: :none,
    effect_id: :none
  })
]

:http_response >> :resolved, [self, effect_id, {:ok, result}] [
  get(self, :state, :pending)
  get_slots(result, %{status_code: status_code, headers: headers, body: body})
  set_slots(self, %{
    state: :completed,
    status_code: status_code,
    headers: headers,
    body: body,
    error: :none,
    effect_id: effect_id
  })
]

:http_response >> :resolved, [self, effect_id, {:error, reason}] [
  get(self, :state, :pending)
  set_slots(self, %{
    state: :failed,
    error: reason,
    effect_id: effect_id
  })
]
