@brick_multi_binding
#{
  super => brick_binding,
  ivars => [
    #{
      element_type => brick_binding,
      name => bindings,
      type => list,
      xaml => xaml_collection_property
    }
  ]
}.

brick_multi_binding >> xaml_tag
| _Self "MultiBinding" |.
