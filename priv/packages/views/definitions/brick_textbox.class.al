@brick_textbox
#{
  super => brick_control,
  ivars => [
    #{name => text, xaml => xaml_binding_property},
    #{
      default => true,
      domain => [false, true],
      name => is_read_only,
      xaml => xaml_literal_property
    },
    #{
      default => "",
      name => placeholder_text,
      type => string,
      xaml => xaml_literal_property
    }
  ]
}.

brick_textbox >> xaml_tag
| _Self "TextBox" |.
