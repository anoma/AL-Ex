@xaml_content_property
#{super => xaml_literal_property}.

xaml_content_property >> xaml_content
| Self Text |
slot_value Self Value,
isa Value brick,
to_xaml Value Text.

xaml_content_property >> xaml_content
| Self Text |
slot_value Self Value,
not (isa Value brick),
call_next_method Self Text.
