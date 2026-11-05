@brick_button
#{
  super => brick_content_control,
  ivars => [
    #{name => flyout, xaml => xaml_content_property},
    #{name => command, xaml => xaml_binding_property},
    #{name => command_parameter, xaml => xaml_literal_property},
    #{name => corner_radius, xaml => xaml_literal_property}
  ]
}.

brick_button >> xaml_tag
| _Self "Button" |.