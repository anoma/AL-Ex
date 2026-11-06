@brick_column_definition
#{
  super => [value, brick],
  ivars => [
    #{default => "*", name => width, xaml => xaml_literal_property},
    #{name => min_width, xaml => xaml_literal_property},
    #{name => max_width, xaml => xaml_literal_property}
  ]
}.

brick_column_definition >> xaml_tag
| _Self "ColumnDefinition" |.