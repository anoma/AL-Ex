@phlow
#{
  super => value,
  ivars => [#{default => 100, name => priority, type => number}, #{name => title}, #{name => view}]
}.

phlow >> to_map
| Self Map |
view_mapping Self View,
= Map #{priority => Priority, title => Title, view => View},
get_slots Self #{priority => Priority, title => Title}.

phlow >> view_mapping
| _Self "empty" |.

phlow >> view
| Self _Builder Self |.

phlow >> view
| Self Builder View |
call_next_method Self Builder View.
