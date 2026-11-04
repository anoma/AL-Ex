@phlow_source
#{super => phlow_xaml, ivars => [#{name => source}]}.

phlow_source >> to_map
| Self Map |
get Self source Read,
run Read [Source],
new brick_source_snippet #{source_record => Source} Brick,
put Self brick Brick View,
call_next_method View Map,
cut.
