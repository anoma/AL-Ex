@brick_decorator
#{
  super => brick_control,
  ivars => [
    #{name => child, type => brick_control, xaml => xaml_object_property},
    #{name => padding, xaml => xaml_literal_property}
  ]
}.

brick_decorator >> xaml_tag
| _Self "Decorator" |.
