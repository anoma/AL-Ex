@xaml_static_property
#{super => xaml_property}.

xaml_static_property >> xaml_content
| Self Text |
slot_value Self Member,
xml_escape Self Member Escaped,
format "<x:Static Member=\"~a\"/>" [Escaped] Text.
