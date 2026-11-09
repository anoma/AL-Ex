@brick_editor_cell
#{
  super => brick_editor_template,
  ivars => [
    #{
      default => "text",
      name => text,
      xaml => xaml_field_binding_property,
      xaml_name => "editor:Code.Text"
    },
    #{
      default => "Disabled",
      name => vertical_scroll_bar_visibility,
      xaml => xaml_literal_property
    },
    #{
      default => "Disabled",
      name => horizontal_scroll_bar_visibility,
      xaml => xaml_literal_property
    },
    #{
      default => true,
      name => follow_caret,
      xaml => xaml_literal_property,
      xaml_name => "editor:Code.FollowCaret"
    }
  ]
}.
