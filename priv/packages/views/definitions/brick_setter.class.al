@brick_setter
#{
  super => [value, brick],
  ivars => [
    #{name => property, type => string, xaml => xaml_literal_property},
    #{name => value, xaml => xaml_content_property}
  ]
}.

brick_setter >> xaml_tag
| _Self "Setter" |.