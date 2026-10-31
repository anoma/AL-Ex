@brick_workspace
#{super => [value, brick_items_control]}.

brick_workspace >> init
| Self Fields Workspace |
new brick_binding #{path => "Windows"} Windows,
new brick_binding #{path => "Extent.Width"} Width,
new brick_binding #{path => "Extent.Height"} Height,
new brick_canvas #{height => Height, width => Width} Canvas,
new brick_binding #{path => "Title"} Title,
new brick_text_block #{dock_panel_dock => "Top", margin => "6,3", text => Title} Heading,
new brick_binding #{path => "Content"} Content,
new brick_content_control #{
  content => Content,
  horizontal_content_alignment => "Stretch",
  vertical_content_alignment => "Stretch"
} Body,
new brick_dock_panel #{children => [Heading, Body]} Panel,
new brick_border #{
  border_brush => "Gray",
  border_thickness => "1",
  child => Panel,
  clip_to_bounds => true
} Frame,
presenter_style Self Style,
put Fields name "Windows" Named,
put Named items_source Windows WithSource,
put WithSource items_panel Canvas WithPanel,
put WithPanel item_template Frame WithTemplate,
put WithTemplate styles [Style] WithStyle,
call_next_method Self WithStyle Workspace.

brick_workspace >> presenter_style
| _Self Style |
lambda [Fields, Setter] Bind {
  get_slots Fields #{path => Path, property => Property},
  new brick_binding #{path => Path} Binding,
  new brick_setter #{property => Property, value => Binding} Setter
},
map [
  #{path => "Rect.X", property => "Canvas.Left"},
  #{path => "Rect.Y", property => "Canvas.Top"},
  #{path => "Rect.Width", property => "Width"},
  #{path => "Rect.Height", property => "Height"}
] Bind Placement,
new brick_setter #{property => "HorizontalContentAlignment", value => "Stretch"} Horizontal,
new brick_setter #{property => "VerticalContentAlignment", value => "Stretch"} Vertical,
concat Placement [Horizontal, Vertical] Setters,
new brick_style #{selector => "ItemsControl#Windows > ContentPresenter", setters => Setters} Style.
