@xaml_template
#{super => xaml_control}.

xaml_template >> to_xaml
| Self Text |
call_next_method Self Content,
format "<DataTemplate>~a</DataTemplate>" [Content] Text.
