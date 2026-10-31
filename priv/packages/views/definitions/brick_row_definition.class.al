@brick_row_definition
#{
  super => [value, brick],
  ivars => [
    #{default => "*", name => height, xaml => xaml_literal_property},
    #{name => min_height, xaml => xaml_literal_property},
    #{name => max_height, xaml => xaml_literal_property}
  ]
}.

brick_row_definition >> xaml_tag
| _Self "RowDefinition" |.
