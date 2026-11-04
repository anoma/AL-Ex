@brick_control
#{
  super => brick,
  ivars => [
    #{name => data_context, xaml => xaml_content_property},
    #{
      name => inspection_target,
      xaml => xaml_content_property,
      xaml_name => "phlow:InspectionTarget.Target"
    },
    #{
      name => bring_into_view_on_focus_change,
      xaml => xaml_literal_property,
      xaml_name => "ScrollViewer.BringIntoViewOnFocusChange"
    },
    #{
      name => navigation_target,
      xaml => xaml_literal_property,
      xaml_name => "editor:Navigation.IsTarget"
    },
    #{name => key_bindings, type => list, xaml => xaml_collection_property},
    #{name => name, type => string, xaml => xaml_literal_property},
    #{name => width, xaml => xaml_content_property},
    #{name => height, xaml => xaml_content_property},
    #{name => min_width, xaml => xaml_literal_property},
    #{name => min_height, xaml => xaml_literal_property},
    #{name => margin, xaml => xaml_literal_property},
    #{name => horizontal_alignment, xaml => xaml_literal_property},
    #{name => vertical_alignment, xaml => xaml_literal_property},
    #{name => clip_to_bounds, xaml => xaml_literal_property},
    #{name => classes, type => string, xaml => xaml_literal_property},
    #{name => class_bindings, xaml => xaml_class_bindings_property},
    #{name => is_visible, xaml => xaml_content_property},
    #{name => opacity, xaml => xaml_literal_property},
    #{name => is_hit_test_visible, xaml => xaml_literal_property},
    #{name => is_enabled, xaml => xaml_content_property},
    #{
      default => [],
      element_type => brick_style,
      name => styles,
      type => list,
      xaml => xaml_collection_property
    },
    #{
      name => grid_row,
      type => number,
      xaml => xaml_literal_property,
      xaml_name => "Grid.Row"
    },
    #{
      name => grid_column,
      type => number,
      xaml => xaml_literal_property,
      xaml_name => "Grid.Column"
    },
    #{
      name => grid_row_span,
      type => number,
      xaml => xaml_literal_property,
      xaml_name => "Grid.RowSpan"
    },
    #{
      name => grid_column_span,
      type => number,
      xaml => xaml_literal_property,
      xaml_name => "Grid.ColumnSpan"
    },
    #{
      name => tool_tip,
      xaml => xaml_literal_property,
      xaml_name => "ToolTip.Tip"
    },
    #{
      name => dock_panel_dock,
      xaml => xaml_literal_property,
      xaml_name => "DockPanel.Dock"
    },
    #{
      name => automation_name,
      type => string,
      xaml => xaml_literal_property,
      xaml_name => "AutomationProperties.Name"
    }
  ]
}.
