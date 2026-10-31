@brick_dock_panel
#{
  super => brick_panel,
  ivars => [#{name => last_child_fill, xaml => xaml_literal_property}]
}.

brick_dock_panel >> xaml_tag
| _Self "DockPanel" |.
