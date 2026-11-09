@filter_input
#{super => object, ivars => [#{default => none, name => subscriber}]}.

filter_input >> subscribe
| Self Subscriber |
set_slot Self subscriber Subscriber.

filter_input >> set_slot
| Self value Value |
cut,
get Self value Value -> pass ; {
  call_next_method Self value Value,
  {
    get Self subscriber Subscriber,
    dif Subscriber none
  } -> refresh Subscriber ; pass
}.

filter_input >> set_slot
| Self Key Value |
dif Key value,
call_next_method Self Key Value.

filter_input >> value_brick
| Self Brick |
label_brick Self Label,
flyout_brick Self Flyout,
new brick_text_block #{
  text => "▾",
  foreground => "#505050",
  vertical_alignment => "Center"
} Arrow,
new brick_stack_panel #{
  children => [Label, Arrow],
  orientation => "Horizontal",
  spacing => 4
} Content,
new brick_tag_button #{content => Content, flyout => Flyout} Brick.

filter_input >> flyout_brick
| Self Flyout |
editor_brick Self Editor,
new brick_flyout #{
  content => Editor,
  placement => "BottomEdgeAlignedLeft"
} Flyout.

filter_input >> label_brick
| Self Brick |
new brick_slot_binding #{object_id => Self, path => value} Value,
new brick_text_block #{
  text => Value,
  foreground => "#1F4D73",
  vertical_alignment => "Center"
} Brick.