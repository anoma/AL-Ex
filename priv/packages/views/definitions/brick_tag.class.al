@brick_tag
#{
  super => brick_control,
  ivars => [
    #{default => 16, name => font_size, xaml => xaml_literal_property},
    #{default => 26, name => min_height, xaml => xaml_literal_property},
    #{default => "6,2", name => padding, xaml => xaml_literal_property},
    #{default => "White", name => background, xaml => xaml_literal_property},
    #{default => "#282828", name => foreground, xaml => xaml_literal_property},
    #{default => "#B8B8B8", name => border_brush, xaml => xaml_content_property},
    #{default => "1", name => border_thickness, xaml => xaml_literal_property},
    #{default => "3", name => corner_radius, xaml => xaml_literal_property}
  ]
}.

brick_tag >> init
| Self Args Self |
call_next_method Self Args Self,
new brick_setter #{property => "ShouldUseOverlayLayer", value => true} Overlay,
new brick_style #{selector => "Popup", setters => [Overlay]} Bounds,
get Self styles Styles,
set_slot Self styles [Bounds . Styles].
