@xaml_items_panel_template_property
#{super => xaml_object_property}.

xaml_items_panel_template_property >> xaml_content
| Self Text |
call_next_method Self Content,
format "<ItemsPanelTemplate>~a</ItemsPanelTemplate>" [Content] Text.
