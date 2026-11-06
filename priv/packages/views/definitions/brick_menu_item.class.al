@brick_menu_item
#{
  super => brick_items_control,
  ivars => [
    #{name => action},
    #{name => header, xaml => xaml_content_property},
    #{name => command, xaml => xaml_binding_property},
    #{name => min_width, xaml => xaml_content_property},
    #{name => padding, xaml => xaml_literal_property},
    #{name => font_size, xaml => xaml_literal_property}
  ]
}.

brick_menu_item >> xaml_tag
| _Self "MenuItem" |.

brick_menu_item >> init
| Self Args Self |
call_next_method Self Args Self,
get Args action _ -> {
  new brick_slot_binding #{object_id => Self, path => action} Command,
  set_slot Self command Command
} ; pass.