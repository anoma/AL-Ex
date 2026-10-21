@brick_table_column
#{super => [value, brick],
  ivars => [#{name => header, default => "", xaml => xaml_literal},
            #{name => width, default => "Auto", xaml => xaml_literal},
            #{name => cell_template, xaml => xaml_template}]}.

brick_table_column >> init
| Self Fields Column |
get Fields cell CellClass,
new CellClass Fields Cell,
put Fields cell_template Cell WithCell,
call_next_method Self WithCell Column.

brick_table_column >> xaml_tag
| _Self "TableViewColumn" |.
