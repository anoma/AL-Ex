@brick_combo_box
#{
  super => brick_items_control,
  ivars => [
    #{name => placeholder_text, xaml => xaml_literal_property},
    #{name => selected_index, xaml => xaml_content_property},
    #{name => padding, xaml => xaml_literal_property},
    #{name => font_size, xaml => xaml_literal_property}
  ]
}.

brick_combo_box >> xaml_tag
| _Self "ComboBox" |.
