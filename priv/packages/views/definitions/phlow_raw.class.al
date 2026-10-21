@phlow_raw
#{super => phlow_xaml, ivars => [#{name => target}]}.

phlow_raw >> init
| Self Fields View |
new brick_editor_template #{} Brick,
put Fields brick Brick WithBrick,
call_next_method Self WithBrick View.

phlow_raw >> to_map
| Self Map |
call_next_method Self Fields,
get Self target Target,
put Fields data Target WithData,
put WithData target Target Map.
