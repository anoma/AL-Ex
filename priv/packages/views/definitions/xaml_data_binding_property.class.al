@xaml_data_binding_property
#{super => xaml_property}.

xaml_data_binding_property >> xaml_content
| Self Text |
slot_value Self Path,
xml_escape Self Path Escaped,
format "<Binding Path=\"~a\" Mode=\"OneWay\"/>" [Escaped] Text.
