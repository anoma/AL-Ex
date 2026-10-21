@xaml_literal
#{super => xaml_slot}.

xaml_literal >> to_xaml
| Self Text |
slot_value Self Value,
atom Value,
atom_string Value Raw,
xml_escape Self Raw Text.

xaml_literal >> to_xaml
| Self Text |
slot_value Self Value,
not (atom Value),
print_object Value Raw,
xml_escape Self Raw Text.
