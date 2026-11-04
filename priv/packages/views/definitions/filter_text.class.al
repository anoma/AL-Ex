@filter_text
#{
  super => filter_input,
  ivars => [#{default => "", name => value, type => string}]
}.

filter_text >> editor_brick
| Self Brick |
new brick_slot_binding #{
  object_id => Self,
  path => value,
  mode => "TwoWay"
} Value,
new brick_editor #{
  text => Value,
  is_read_only => false,
  min_width => 180,
  min_height => 28,
  font_size => 16,
  padding => "6,4"
} Brick.
