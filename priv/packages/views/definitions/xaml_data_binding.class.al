@xaml_data_binding
#{super => xaml_slot}.

xaml_data_binding >> to_xaml
| Self Text |
slot_value Self Path,
xml_escape Self Path Escaped,
format "<Binding Path=\"~a\" Mode=\"OneWay\"/>" [Escaped] Text.
