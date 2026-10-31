@class_up_to_filter
#{
  super => brick_control,
  ivars => [
    #{name => target},
    #{name => classes, type => list},
    #{name => options, type => observable_list},
    #{name => index, type => number},
    #{name => subscriber}
  ]
}.

class_up_to_filter >> init
| Self Args Self |
call_next_method Self Args Self,
get Self target Target,
reachable_classes [Target] [] Classes,
lambda [Class, Text] Name (atom_string Class Text),
map Classes Name Names,
new observable_list Names Options,
set_slots Self #{classes => Classes, options => Options},
set_slot Self index 0.

class_up_to_filter >> accepts
| Self Class |
get_slots Self #{classes => Classes, index => Index},
length Prefix Index,
concat Prefix [Last . _Rest] Classes,
concat Prefix [Last] Included,
member Included Class.

class_up_to_filter >> subscribe
| Self Subscriber |
set_slot Self subscriber Subscriber.

class_up_to_filter >> set_slot
| Self index Index |
get Self classes Classes,
at Classes Index _,
call_next_method Self index Index,
get Self subscriber Subscriber -> refresh Subscriber ; pass.

class_up_to_filter >> set_slot
| Self Key Value |
dif Key index,
call_next_method Self Key Value.

class_up_to_filter >> to_xaml
| Self Text |
new brick_text_block #{font_size => 14, text => "Class up to", vertical_alignment => "Center"} Label,
new brick_slot_binding #{object_id => Self, path => options} Items,
new brick_slot_binding #{mode => "TwoWay", object_id => Self, path => index} Index,
new brick_binding #{converter => "al:Data.Field"} ItemText,
new brick_text_block #{font_size => 14, text => ItemText} Item,
new brick_combo_box #{
  font_size => 14,
  item_template => Item,
  items_source => Items,
  min_height => 24,
  padding => "4,0",
  selected_index => Index
} Choices,
new brick_stack_panel #{children => [Label, Choices], orientation => "Horizontal", spacing => 4} Bar,
to_xaml Bar Text.
