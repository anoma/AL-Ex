@phlow_views
#{
  super => phlow,
  ivars => [#{name => target}, #{default => view, name => selector}]
}.

phlow_views >> view_mapping
| _Self "inspector" |.

phlow_views >> to_map
| Self Map |
call_next_method Self Fields,
get_slots Self #{selector => Selector, target => Target},
new phlow_builder #{} Builder,
findall Description Views {
  send Target Selector [Builder, View],
  view_mapping View Kind,
  dif Kind "empty",
  get_slots View #{priority => Priority, title => Title},
  = Description #{priority => Priority, title => Title, value => View, view => "deferred"}
},
put Fields views Views Map.