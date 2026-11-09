@brick_panel
#{
  super => brick_control,
  ivars => [
    #{
      default => [],
      element_type => brick_control,
      name => children,
      type => list,
      xaml => xaml_collection_property
    },
    #{name => background, xaml => xaml_literal_property}
  ]
}.

brick_panel >> xaml_tag
| _Self "Panel" |.
