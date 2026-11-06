@brick_grid
#{
  super => brick_panel,
  ivars => [
    #{
      default => [],
      element_type => brick_row_definition,
      name => row_definitions,
      type => list,
      xaml => xaml_collection_property
    },
    #{
      default => [],
      element_type => brick_column_definition,
      name => column_definitions,
      type => list,
      xaml => xaml_collection_property
    }
  ]
}.

brick_grid >> xaml_tag
| _Self "Grid" |.