@brick_menu_flyout
#{
  super => brick,
  ivars => [
    #{name => items, type => list, xaml => xaml_collection_property},
    #{name => placement, xaml => xaml_literal_property}
  ]
}.

brick_menu_flyout >> xaml_tag
| _Self "MenuFlyout" |.
