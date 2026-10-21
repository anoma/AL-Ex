@brick_editor_options
#{super => [value, brick],
  ivars => [#{name => allow_scroll_below_document,
              default => false,
              domain => [false, true],
              xaml => xaml_literal}]}.

brick_editor_options >> xaml_tag
| _Self "ae:TextEditorOptions" |.
