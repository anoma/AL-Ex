@brick_window
#{super => [value, brick_border], ivars => [#{name => target}]}.

brick_window >> init
| Self Fields Brick |
get Fields target Window,
new brick_slot_binding #{
  object_id => Window,
  path => "position",
  converter => "al:Data.Offset"
} Position,
new brick_slot_binding #{
  object_id => Window,
  path => "extent",
  converter => "al:Data.Number",
  converter_parameter => "x"
} Width,
new brick_slot_binding #{
  object_id => Window,
  path => "extent",
  converter => "al:Data.Number",
  converter_parameter => "y"
} Height,
new brick_slot_binding #{object_id => Window, path => "content"} Content,
new brick_slot_binding #{
  object_id => Window,
  path => "content",
  converter => "al:Data.Field",
  converter_parameter => "title"
} Title,
new brick_text_block #{dock_panel_dock => "Top", margin => "6,3", text => Title} Heading,
new brick_content_control #{
  content => Content,
  content_template => "phlow:PhlowBuilder.Template",
  horizontal_content_alignment => "Stretch",
  vertical_content_alignment => "Stretch"
} Body,
new brick_dock_panel #{children => [Heading, Body]} Panel,
put Fields child Panel WithChild,
put WithChild margin Position Positioned,
put Positioned width Width WithWidth,
put WithWidth height Height WithHeight,
put WithHeight border_brush "Gray" Bordered,
put Bordered border_thickness "1" Framed,
put Framed clip_to_bounds true Clipped,
put Clipped horizontal_alignment "Left" LeftAligned,
put LeftAligned vertical_alignment "Top" TopAligned,
call_next_method Self TopAligned Brick.