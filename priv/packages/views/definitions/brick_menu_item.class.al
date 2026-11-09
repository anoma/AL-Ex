@brick_menu_item
#{
  super => brick_items_control,
  ivars => [
    #{name => header, xaml => xaml_content_property},
    #{name => command, xaml => xaml_binding_property}
  ]
}.

brick_menu_item >> xaml_tag
| _Self "MenuItem" |.
