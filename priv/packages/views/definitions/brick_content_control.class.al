@brick_content_control
#{
  super => brick_control,
  ivars => [
    #{name => content, xaml => xaml_content_property},
    #{name => content_template, xaml => xaml_static_property},
    #{name => horizontal_content_alignment, xaml => xaml_literal_property},
    #{name => vertical_content_alignment, xaml => xaml_literal_property},
    #{name => padding, xaml => xaml_literal_property},
    #{name => background, xaml => xaml_literal_property},
    #{name => foreground, xaml => xaml_literal_property},
    #{name => border_brush, xaml => xaml_content_property},
    #{name => border_thickness, xaml => xaml_literal_property},
    #{name => font_size, xaml => xaml_literal_property},
    #{name => font_family, xaml => xaml_literal_property}
  ]
}.

brick_content_control >> xaml_tag
| _Self "ContentControl" |.