@phlow_clist
#{super => phlow, ivars => [#{name => items}, #{name => columns}]}.

phlow_clist >> to_map
| Self Map |
call_next_method Self Map1,
put Map1 items Items Map2,
put Map2 columns Columns Map,
get_slots Self #{items => Items, columns => Columns}.

phlow_clist >> view_mapping
| _Self "columned_list" |.
