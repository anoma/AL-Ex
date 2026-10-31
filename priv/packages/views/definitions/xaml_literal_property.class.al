@xaml_literal_property
#{super => xaml_property}.

xaml_literal_property >> xaml_content
| Self Text |
slot_value Self Value,
atom Value,
atom_string Value Raw,
xml_escape Self Raw Text.

xaml_literal_property >> xaml_content
| Self Text |
slot_value Self Value,
not (atom Value),
print_object Value Raw,
xml_escape Self Raw Text.
