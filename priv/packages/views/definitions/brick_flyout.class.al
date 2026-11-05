@brick_flyout
#{
  super => brick,
  ivars => [
    #{name => content, xaml => xaml_content_property},
    #{name => placement, xaml => xaml_literal_property}
  ]
}.

brick_flyout >> xaml_tag
| _Self "Flyout" |.