@brick_editor
#{
  super => brick_control,
  ivars => [
    #{
      name => text,
      xaml => xaml_binding_property,
      xaml_name => "editor:Code.Text"
    },
    #{
      default => "",
      name => grammar,
      xaml => xaml_content_property,
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
    },
    #{name => font_size, xaml => xaml_literal_property},
    #{
      default => "Fira Code,avares://Aguil/Assets/Fonts#Fira Code",
      name => font_family,
      xaml => xaml_literal_property
    },
    #{name => padding, xaml => xaml_literal_property},
    #{
      name => original_text,
      xaml => xaml_content_property,
      xaml_name => "editor:Code.OriginalText"
    },
    #{name => vertical_scroll_bar_visibility, xaml => xaml_literal_property},
    #{name => horizontal_scroll_bar_visibility, xaml => xaml_literal_property},
    #{
      name => fold_after_line,
      xaml => xaml_literal_property,
      xaml_name => "editor:Code.FoldAfterLine"
    },
    #{
      name => is_folded,
      xaml => xaml_content_property,
      xaml_name => "editor:Code.IsFolded"
    },
    #{
      name => before_command,
      xaml => xaml_content_property,
      xaml_name => "editor:Code.BeforeCommand"
    },
    #{
      name => after_command,
      xaml => xaml_content_property,
      xaml_name => "editor:Code.AfterCommand"
    },
    #{
      name => follow_caret,
      xaml => xaml_literal_property,
      xaml_name => "editor:Code.FollowCaret"
    }
  ]
}.

brick_editor >> xaml_tag
| _Self "ae:TextEditor" |.