@wm
#{
  super => object,
  ivars => [
    #{name => layout, type => layout},
    #{name => visible_extent, type => point},
    #{name => content, type => phlow}
  ]
}.

wm >> new_window
| Self Request |
get Self layout Layout,
place_window Layout Self Request NewLayout,
layout_changed Self NewLayout.

wm >> visible_extent
| Self Vis |
get Self visible_extent Vis.

wm >> viewport_changed
| Self Visible |
get Self layout Layout,
set_slot Self visible_extent Visible,
resize Layout Self NewLayout,
layout_changed Self NewLayout.

wm >> init
| Self Fields Self |
get Fields layout Layout -> pass ; new single_layout #{} Layout,
put Fields layout Layout WithLayout,
call_next_method Self WithLayout Self,
layout_changed Self Layout.

wm >> layout_changed
| Self Layout |
{get Self layout Layout, get Self content _View} -> pass ; {
  brick Layout Brick,
  new phlow_xaml #{title => "", brick => Brick} View,
  set_slot Self content View
},
set_slot Self layout Layout.

wm >> to_xaml
| Self Text |
new brick_slot_binding #{object_id => Self, path => "content"} Content,
new brick_content_control #{
  content => Content,
  content_template => "phlow:PhlowBuilder.Template",
  horizontal_content_alignment => "Stretch",
  vertical_content_alignment => "Stretch"
} Brick,
to_xaml Brick Text.