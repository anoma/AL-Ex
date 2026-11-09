@brick_border
#{
  super => brick_decorator,
  ivars => [
    #{name => background, xaml => xaml_literal_property},
    #{name => border_brush, xaml => xaml_literal_property},
    #{name => border_thickness, xaml => xaml_literal_property},
    #{name => corner_radius, xaml => xaml_literal_property}
  ]
}.

brick_border >> xaml_tag
| _Self "Border" |.
