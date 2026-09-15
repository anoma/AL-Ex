Class {
  #name : :http_request,
  #superclass : [:object],
  #metaclass : :class,
  #ivars : [
    method: [],
    url: [],
    headers: [],
    body: [],
    timeout: []
  ]
}

:http_request >> :init, [self, args, self] [
  get_slots(args, %{
    method: method,
    url: url,
    headers: headers,
    body: body,
    timeout: timeout
  })
  set_slots(self, %{
    method: method,
    url: url,
    headers: headers,
    body: body,
    timeout: timeout
  })
]

:http_request >> :execute, [self, response] [
  get_slots(self, %{
    method: method,
    url: url,
    headers: headers,
    body: body,
    timeout: timeout
  })
  new(:http_response, response)
  emit_effect(
    :http,
    :execute,
    [method, url, headers, body, timeout],
    {response, :resolved, []}
  )
]
