@brick_editor_options
#{
  super => [value, brick],
  ivars => [
    #{
      default => false,
      domain => [false, true],
      name => allow_scroll_below_document,
      xaml => xaml_literal_property
    }
  ]
}.

brick_editor_options >> xaml_tag
| _Self "ae:TextEditorOptions" |.