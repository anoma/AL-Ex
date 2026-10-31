@brick_text
#{
  super => [value, brick],
  ivars => [
    #{default => "text", name => text, xaml => xaml_field_binding_property},
    #{
      default => "Transparent",
      name => background,
      xaml => xaml_literal_property
    }
  ]
}.

brick_text >> xaml_tag
| _Self "TextBlock" |.
