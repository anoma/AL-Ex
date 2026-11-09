@brick_path_icon
#{
  super => brick_control,
  ivars => [
    #{name => data, type => string, xaml => xaml_literal_property},
    #{name => foreground, xaml => xaml_literal_property}
  ]
}.

brick_path_icon >> xaml_tag
| _Self "PathIcon" |.
