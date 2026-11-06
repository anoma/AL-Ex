@brick_key_binding
#{
  super => [value, brick],
  ivars => [
    #{name => gesture, xaml => xaml_literal_property},
    #{name => command, xaml => xaml_content_property}
  ]
}.

brick_key_binding >> xaml_tag
| _Self "KeyBinding" |.