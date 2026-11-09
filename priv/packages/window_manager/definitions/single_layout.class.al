@single_layout
#{super => layout}.

single_layout >> place_window
| Self Wm Request Self |
get Request content Content,
new point #{} Origin,
visible_extent Wm Ext,
new window #{content => Content, extent => Ext, position => Origin} Window,
get Self windows Windows,
replace Windows [Window].

single_layout >> resize
| Self Wm Self |
visible_extent Wm Visible,
get Self windows Windows,
get Windows contents Items,
forall {member Items Window} {set_slot Window extent Visible}.