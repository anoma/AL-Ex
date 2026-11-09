@brick_binding
#{
  super => [value, brick],
  ivars => [
    #{name => path, type => string, xaml => xaml_literal_property},
    #{name => element_name, type => string, xaml => xaml_literal_property},
    #{name => mode, xaml => xaml_literal_property},
    #{name => converter, type => string, xaml => xaml_static_property},
    #{name => converter_parameter, xaml => xaml_content_property}
  ]
}.

brick_binding >> xaml_tag
| _Self "Binding" |.
