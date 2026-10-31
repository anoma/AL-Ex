@wm
#{
  super => object,
  ivars => [
    #{name => layout, type => layout},
    #{default => 0, name => curr_id, type => number},
    #{name => visible_extent, type => point},
    #{name => total_extent, type => point},
    #{default => "", name => xaml, type => string},
    #{default => #{}, name => changes}
  ]
}.

wm >> new_window
| Self Request Changed Removed |
get Self layout Layout,
get Self curr_id CurrId,
put Request id CurrId RequestWithId,
place_window Layout Self RequestWithId NewLayout,
= NewId (+ CurrId 1),
set_slot Self curr_id NewId,
layout_changed Self NewLayout Changed Removed.

wm >> visible_extent
| Self Vis |
get Self visible_extent Vis.

wm >> viewport_changed
| Self Visible Changed Removed |
get Self layout Layout,
set_slot Self visible_extent Visible,
resize Layout Self NewLayout,
get Self xaml Xaml,
apply_layout Self NewLayout Xaml Changed Removed.

wm >> init
| Self Fields Self |
call_next_method Self Fields Self,
get Self layout Layout,
layout_changed Self Layout _ _.

wm >> layout_changed
| Self NewLayout Changed Removed |
to_xaml NewLayout Xaml,
apply_layout Self NewLayout Xaml Changed Removed.

wm >> apply_layout
| Self NewLayout Xaml Changed Removed |
get Self layout Layout,
extent NewLayout Total,
placement_changes NewLayout Layout Changed Removed,
set_slots Self #{
  changes => #{changed => Changed, extent => Total, removed => Removed, xaml => Xaml},
  layout => NewLayout,
  total_extent => Total,
  xaml => Xaml
}.
