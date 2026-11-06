@xaml_content_property
#{super => xaml_literal_property}.

xaml_content_property >> xaml_content
| Self Value Text |
isa Value brick,
to_xaml Value Text.

xaml_content_property >> xaml_content
| Self Value Text |
not (isa Value brick),
call_next_method Self Value Text.