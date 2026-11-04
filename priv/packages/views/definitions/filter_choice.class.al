@filter_choice
#{
  super => filter_input,
  ivars => [
    #{name => choices, type => list},
    #{name => value, type => number},
    #{name => display, type => string}
  ]
}.

filter_choice >> init
| Self Args Self |
get Args choices Choices,
set_slot Self choices Choices,
call_next_method Self Args Self,
get Args value 0 Index,
set_slot Self value Index.

filter_choice >> set_slot
| Self value Index |
get Self choices Choices,
at Choices Index Choice,
cut,
get Self value Index -> pass ; {
  format "~a" [Choice] Text,
  set_slot Self display Text,
  call_next_method Self value Index
}.

filter_choice >> set_slot
| Self Key Value |
dif Key value,
call_next_method Self Key Value.

filter_choice >> value_brick
| Self Brick |
get Self choices Choices,
lambda [Choice, Item] Label {
  format "~a" [Choice] Text,
  new brick_text_block #{text => Text} Item
},
map Choices Label Items,
new brick_slot_binding #{
  object_id => Self,
  path => value,
  mode => "TwoWay"
} Index,
new brick_tag_combo_box #{items => Items, selected_index => Index} Brick.
