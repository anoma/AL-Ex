@phlow_text
#{super => phlow, ivars => [#{name => text}, #{name => grammar}]}.

phlow_text >> to_map
| Self Map |
call_next_method Self Map1,
put Map1 text Text Map2,
put Map2 grammar Grammar Map,
get_slots Self #{text => Text, grammar => Grammar}.

phlow_text >> view_mapping
| _Self "text" |.
