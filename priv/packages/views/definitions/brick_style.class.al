@brick_style
#{
  super => [value, brick],
  ivars => [
    #{name => selector, type => string, xaml => xaml_literal_property},
    #{
      default => [],
      element_type => brick_setter,
      name => setters,
      type => list,
      xaml => xaml_collection_property
    }
  ]
}.

brick_style >> xaml_tag
| _Self "Style" |.