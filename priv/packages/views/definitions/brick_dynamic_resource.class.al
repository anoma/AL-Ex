@brick_dynamic_resource
#{
  super => [value, brick],
  ivars => [#{name => resource_key, type => string, xaml => xaml_literal_property}]
}.

brick_dynamic_resource >> xaml_tag
| _Self "DynamicResource" |.