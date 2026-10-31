@brick_stack_panel
#{
  super => brick_panel,
  ivars => [
    #{name => orientation, xaml => xaml_literal_property},
    #{name => spacing, xaml => xaml_literal_property}
  ]
}.

brick_stack_panel >> xaml_tag
| _Self "StackPanel" |.
