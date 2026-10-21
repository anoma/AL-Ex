@phlow_xaml
#{super => phlow, ivars => [#{name => brick, type => brick}]}.

phlow_xaml >> to_map
| Self Map |
get_slots Self #{brick => Brick},
call_next_method Self Map1,

to_xaml Brick BrickText,
put Map1 content BrickText Map.

phlow_xaml >> view_mapping
| _Self "xaml" |.
