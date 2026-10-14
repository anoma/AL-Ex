@single_layout
#{super => layout, ivars => []}.

single_layout >> place_window
| Self Wm Request NewLayout |
get Request id Id,
get Request content Content,
class Self Class,
new point #{} Origin,
visible_extent Wm Ext,
new window #{content => Content, id => Id, extent => Ext, position => Origin} Window,
new Class #{windows => [Window]} NewLayout.

single_layout >> resize
| Self _Wm Self |
get Self windows [].

single_layout >> resize
| Self Wm NewLayout |
get Self windows [Window],
visible_extent Wm Visible,
put Window extent Visible ResizedWindow,
put Self windows [ResizedWindow] NewLayout.
