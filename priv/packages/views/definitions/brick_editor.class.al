@brick_editor
#{
  super => brick,
  ivars => [
    #{
      name => text,
      type => string,
      xaml => xaml_binding_property,
      xaml_name => "editor:Code.Text"
    },
    #{
      default => "",
      name => grammar,
      type => string,
      xaml => xaml_literal_property,
      xaml_name => "editor:Code.Grammar"
    },
    #{
      default => true,
      domain => [false, true],
      name => is_read_only,
      xaml => xaml_literal_property
    },
    #{
      default => #{allow_scroll_below_document => false, class => brick_editor_options},
      name => options,
      type => brick_editor_options,
      xaml => xaml_object_property
    }
  ]
}.

brick_editor >> xaml_tag
| _Self "ae:TextEditor" |.
