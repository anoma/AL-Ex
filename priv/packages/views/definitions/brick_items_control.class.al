@brick_items_control
#{
  super => brick_control,
  ivars => [
    #{name => items, type => list, xaml => xaml_collection_property},
    #{name => items_source, xaml => xaml_content_property},
    #{
      name => items_panel,
      type => brick_panel,
      xaml => xaml_items_panel_template_property
    },
    #{
      name => item_template,
      type => brick_control,
      xaml => xaml_template_property
    }
  ]
}.

brick_items_control >> xaml_tag
| _Self "ItemsControl" |.