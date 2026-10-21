@brick_editor
#{super => brick,
  ivars => [
    #{name => text,
      type => string,
      xaml => xaml_binding,
      xaml_name => "editor:Code.Text"},
    #{name => grammar,
      type => string,
      default => "",
      xaml => xaml_literal,
      xaml_name => "editor:Code.Grammar"},
    #{name => is_read_only,
      default => true,
      domain => [false, true],
      xaml => xaml_literal},
    #{name => options,
      type => brick_editor_options,
      default => #{class => brick_editor_options, allow_scroll_below_document => false},
      xaml => xaml_control}]}.

brick_editor >> xaml_tag
| _Self "ae:TextEditor" |.
