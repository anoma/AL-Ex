@phlow_clist
#{super => phlow_xaml, ivars => [#{name => items}]}.

phlow_clist >> init
| Self Fields View |
new brick_table Fields Brick,
put Fields brick Brick WithBrick,
call_next_method Self WithBrick View.

phlow_clist >> to_map
| Self Map |
call_next_method Self Fields,
get Self items Items,
put Fields data Items Map.