@xaml_static_property
#{super => xaml_property}.

xaml_static_property >> xaml_content
| Self Member Text |
xml_escape Self Member Escaped,
format "<x:Static Member=\"~a\"/>" [Escaped] Text.