@brick_table_column
#{
  super => [value, brick],
  ivars => [
    #{default => "", name => header, xaml => xaml_literal_property},
    #{default => "Auto", name => width, xaml => xaml_literal_property},
    #{name => cell_template, xaml => xaml_template_property}
  ]
}.

brick_table_column >> init
| Self Fields Column |
get Fields cell CellClass,
new CellClass Fields Cell,
put Fields cell_template Cell WithCell,
call_next_method Self WithCell Column.

brick_table_column >> xaml_tag
| _Self "TableViewColumn" |.
