@brick_text
#{super => [value, brick],
  ivars => [#{name => text, default => "text", xaml => xaml_field_binding},
            #{name => background, default => "Transparent", xaml => xaml_literal}]}.

brick_text >> xaml_tag
| _Self "TextBlock" |.
