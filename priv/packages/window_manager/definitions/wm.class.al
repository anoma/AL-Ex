@wm
#{
  super => object,
  ivars => [
    #{name => layout, type => layout},
    #{default => 0, name => curr_id, type => number},
    #{name => visible_extent, type => point},
    #{name => total_extent, type => point}
  ]
}.

wm >> new_window
| Self Request Changed Removed |
get Self layout Layout,
get Self curr_id CurrId,
put Request id CurrId RequestWithId,
place_window Layout Self RequestWithId NewLayout,
extent NewLayout NewExtent,
= NewId (+ CurrId 1),
placement_changes NewLayout Layout Changed Removed,
set_slots Self #{layout => NewLayout, total_extent => NewExtent, curr_id => NewId}.

wm >> visible_extent
| Self Vis |
get Self visible_extent Vis.

wm >> viewport_changed
| Self Visible Changed Removed |
get Self layout Layout,
set_slot Self visible_extent Visible,
resize Layout Self NewLayout,
extent NewLayout Total,
placement_changes NewLayout Layout Changed Removed,
set_slots Self #{layout => NewLayout, total_extent => Total}.
