@xaml_literal_property
#{super => xaml_property}.

xaml_literal_property >> xaml_content
| Self Value Text |
atom Value,
atom_string Value Raw,
xml_escape Self Raw Text.

xaml_literal_property >> xaml_content
| Self Value Text |
not (atom Value),
format "~a" [Value] Raw,
xml_escape Self Raw Text.
