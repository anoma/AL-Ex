@brick_slot_binding
#{
  super => [value, brick],
  ivars => [
    #{name => object_id, xaml => xaml_content_property},
    #{name => path, xaml => xaml_literal_property},
    #{name => mode, xaml => xaml_literal_property}
  ]
}.

brick_slot_binding >> init
| Self Args Binding |
get Args object_id Id,
atom Id -> {
  atom_string Id Text,
  put Args object_id Text Fields
} ; = Fields Args,
call_next_method Self Fields Binding.

brick_slot_binding >> xaml_tag
| _Self "al:BindExtension" |.
