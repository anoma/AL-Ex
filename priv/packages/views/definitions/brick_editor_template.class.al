@brick_editor_template
#{
  super => [value, brick_editor],
  ivars => [
    #{
      default => ".",
      name => text,
      type => string,
      xaml => xaml_data_binding_property,
      xaml_name => "editor:Code.Text"
    }
  ]
}.