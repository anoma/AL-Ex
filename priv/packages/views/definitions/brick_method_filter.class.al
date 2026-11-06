@brick_method_filter
#{
  super => brick,
  ivars => [#{name => filter, type => method_filter}, #{name => remove_action}]
}.

brick_method_filter >> to_xaml
| Self Text |
make_grid Self Grid,
to_xaml Grid Text.

brick_method_filter >> make_grid
| Self Grid |
get Self filter Filter,
name_brick Filter Name,
value_brick Filter Value,
new brick_stack_panel #{
  children => [Name, Value],
  orientation => "Horizontal",
  spacing => 6
} Content,
new brick_border #{
  child => Content,
  background => "#F0F0F0",
  border_brush => "#D6D6D6",
  border_thickness => "1",
  corner_radius => "4",
  padding => "4,2"
} Group,
new brick_slot_binding #{object_id => Self, path => remove_action} Remove,
new brick_tag_button #{
  classes => "close",
  command => Remove,
  content => "×",
  width => 16,
  height => 16,
  min_width => 0,
  min_height => 0,
  padding => "0",
  corner_radius => "8",
  margin => "0,-4,-4,0",
  horizontal_alignment => "Right",
  vertical_alignment => "Top"
} Close,
new brick_setter #{property => "Opacity", value => 0} Hidden,
new brick_setter #{property => "IsHitTestVisible", value => false} NoHit,
new brick_style #{
  selector => "Grid.filter:not(:pointerover) > Button.close",
  setters => [Hidden, NoHit]
} HideClose,
new brick_grid #{
  classes => "filter",
  children => [Group, Close],
  styles => [HideClose],
  clip_to_bounds => false
} Grid.