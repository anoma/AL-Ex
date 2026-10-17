@brick_textbox
#{
  super => brick,
  ivars => [
    #{name => text, type => string, xaml => xaml_binding},
    #{
      default => true,
      domain => [false, true],
      name => is_read_only,
      xaml => xaml_literal
    },
    #{
      default => "",
      name => placeholder_text,
      type => string,
      xaml => xaml_literal
    }
  ]
}.

brick_textbox >> xaml_tag
  | _Self "TextBox" |.