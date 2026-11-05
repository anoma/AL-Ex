@brick_text_block
#{
  super => brick_control,
  ivars => [
    #{default => "", name => text, xaml => xaml_content_property},
    #{name => font_size, xaml => xaml_literal_property},
    #{name => font_family, xaml => xaml_literal_property},
    #{name => foreground, xaml => xaml_literal_property},
    #{name => text_wrapping, xaml => xaml_literal_property},
    #{name => background, xaml => xaml_literal_property}
  ]
}.

brick_text_block >> xaml_tag
| _Self "TextBlock" |.