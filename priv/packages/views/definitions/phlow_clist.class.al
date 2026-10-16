@phlow_clist
#{
  super => phlow,
  ivars => [
    #{name => items},
    #{name => columns},
    #{name => row_spacing, default => 0}
  ]
}.

phlow_clist >> to_map
| Self Map |
call_next_method Self Map1,
put Map1 items Items Map2,
put Map2 columns Columns Map3,
put Map3 row_spacing RowSpacing Map,
get_slots Self #{items => Items, columns => Columns, row_spacing => RowSpacing}.

phlow_clist >> view_mapping
| _Self "columned_list" |.
