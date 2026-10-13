@phlow_csharp_forward
#{super => phlow, ivars => [#{name => target}]}.

phlow_csharp_forward >> view_mapping
| Self View |
get Self view View.

phlow_csharp_forward >> to_map
| Self Map |
call_next_method Self Fields,
get Self target Target,
put Fields target Target Map.
