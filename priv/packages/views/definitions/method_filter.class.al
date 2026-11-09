@method_filter
#{
  super => object,
  ivars => [
    #{name => title, type => string},
    #{default => false, domain => [false, true], name => on_by_default},
    #{name => input, type => filter_input},
    #{name => predicate},
    #{default => none, name => subscriber},
    #{name => add_action},
    #{name => remove_action},
    #{default => true, domain => [false, true], name => can_add}
  ]
}.

method_filter >> init
| Self Args Self |
call_next_method Self Args Self,
get Self input Input,
subscribe Input Self.

method_filter >> accepts
| Self Source |
get_slots Self #{input => Input, predicate => Predicate},
get Input value Value,
run Predicate [Value, Source].

method_filter >> subscribe
| Self Subscriber |
set_slot Self subscriber Subscriber.

method_filter >> refresh
| Self |
{
  get Self subscriber Subscriber,
  dif Subscriber none
} -> refresh Subscriber ; pass.

method_filter >> name_brick
| Self Brick |
get Self title Name,
new brick_text_block #{
  text => Name,
  font_size => 16,
  foreground => "#343434",
  vertical_alignment => "Center"
} Brick.

method_filter >> value_brick
| Self Brick |
get Self input Input,
value_brick Input Brick.

method_filter >> to_xaml
| Self Text |
get Self remove_action Remove,
new brick_method_filter #{filter => Self, remove_action => Remove} Brick,
to_xaml Brick Text.