@xaml_field_binding_property
#{super => xaml_property}.

xaml_field_binding_property >> xaml_content
| Self Field Text |
xml_escape Self Field Escaped,
format "<Binding Converter=\"{x:Static al:Data.Field}\" ConverterParameter=\"~a\" Mode=\"OneWay\"/>" [Escaped] Text.
