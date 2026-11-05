@method_filters
#{
  super => observable_list,
  ivars => [#{name => target}, #{name => available, type => list}, #{name => subscriber}]
}.

method_filters >> init
| Self Args Self |
get Args target Target,
findall Filter Available {method_filter Target Filter},
set_slots Self #{target => Target, available => Available, subscriber => none},
forall (member Available Filter) {
  lambda [] Add (add_filter Self Filter),
  lambda [] Remove (remove_filter Self Filter),
  set_slots Filter #{add_action => Add, remove_action => Remove}
},
findall Filter Defaults {
  member Available Filter,
  get Filter on_by_default true
},
call_next_method Self Defaults Self,
get Args subscriber none Subscriber,
set_slot Self subscriber Subscriber.

method_filters >> set_slot
| Self contents Items |
cut,
get Self available Available,
all_dif Items,
forall (member Items Filter) (member Available Filter),
call_next_method Self contents Items,
forall (member Available Filter) {
  member Items Filter -> {
    subscribe Filter Self,
    set_slot Filter can_add false
  } ; {
    subscribe Filter none,
    set_slot Filter can_add true
  }
},
refresh Self.

method_filters >> set_slot
| Self Key Value |
dif Key contents,
call_next_method Self Key Value.

method_filters >> add_filter
| Self Filter |
get Self contents Items,
member Items Filter -> pass ; {
  length Items Index,
  insert Self Index Filter
}.

method_filters >> remove_filter
| Self Filter |
get Self contents Items,
at Items Index Filter -> remove Self Index ; pass.

method_filters >> refresh
| Self |
{
  get Self subscriber Subscriber,
  dif Subscriber none
} -> refresh Subscriber ; pass.

method_filters >> bar_brick
| Self Binding Bar |
new brick_stack_panel #{orientation => "Horizontal", spacing => 6} Panel,
new brick_items_control #{
  items_source => Binding,
  items_panel => Panel,
  vertical_alignment => "Center"
} Active,
get Self available Available,
lambda [Filter, Item] Choice {
  get Filter title Name,
  new brick_slot_binding #{object_id => Filter, path => add_action} Add,
  new brick_slot_binding #{object_id => Filter, path => can_add} Enabled,
  new brick_menu_item #{
    header => Name,
    command => Add,
    is_enabled => Enabled,
    font_size => 16,
    min_height => 28,
    padding => "8,2"
  } Item
},
map Available Choice Choices,
new brick_menu_flyout #{items => Choices} Menu,
new brick_tag_button #{
  content => "+",
  flyout => Menu,
  padding => "8,2",
  vertical_alignment => "Center"
} Add,
new brick_stack_panel #{
  children => [Active, Add],
  orientation => "Horizontal",
  spacing => 6,
  margin => "4,6"
} Bar.