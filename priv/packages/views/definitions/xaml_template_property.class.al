@xaml_template_property
#{super => xaml_object_property}.

xaml_template_property >> xaml_content
| Self Text |
call_next_method Self Content,
format "<DataTemplate>~a</DataTemplate>" [Content] Text.
