@http_request
#{
  super => object,
  ivars => [
    #{name => method},
    #{name => url},
    #{name => headers},
    #{name => body},
    #{name => timeout}
  ]
}.

http_request >> init
| Self Args Self |
get_slots Args #{body => Body, headers => Headers, method => Method, timeout => Timeout, url => Url},
set_slots Self #{body => Body, headers => Headers, method => Method, timeout => Timeout, url => Url}.

http_request >> execute
| Self Response |
get_slots Self #{body => Body, headers => Headers, method => Method, timeout => Timeout, url => Url},
new effect #{
  arguments => [Method, Url, Headers, Body, Timeout],
  operation => execute,
  provider => http
} Response.