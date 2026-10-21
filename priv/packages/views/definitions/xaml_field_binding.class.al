@xaml_field_binding
#{super => xaml_slot}.

xaml_field_binding >> to_xaml
| Self Text |
slot_value Self Field,
xml_escape Self Field Escaped,
format "<Binding Converter=\"{x:Static al:Data.Field}\" ConverterParameter=\"~a\" Mode=\"OneWay\"/>" [Escaped] Text.
