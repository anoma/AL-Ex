@xaml_slot
#{super => value, ivars => [#{name => owner}, #{name => spec}]}.

xaml_slot >> xaml_property
  | Self Text |
xaml_name Self Name,
to_xaml Self Content,
format "<~a>~a</~a>" [Name, Content, Name] Text.

xaml_slot >> slot_value
  | Self Value |
get_slots Self #{owner => Owner, spec => Spec},
get_slots Spec #{name => Slot},
get Owner Slot Value.

xaml_slot >> to_xaml
  | _Self _Text |
fail.

xaml_slot >> xaml_name
  | Self Name |
get_slots Self #{spec => Spec},
get_slots Spec #{xaml_name => Name}.

xaml_slot >> xaml_name
  | Self Name |
get_slots Self #{owner => Owner, spec => Spec},
not (get Spec xaml_name _),
get_slots Spec #{name => Slot},
atom_string Slot Raw,
pascal_case Self Raw Property,
xaml_tag Owner Tag,
format "~a.~a" [Tag, Property] Name.

xaml_slot >> pascal_case
  | Self Raw Name |
string_codes Raw Codes,
pascal_codes Self Codes Capitalized,
string_codes Name Capitalized.

xaml_slot >> pascal_codes
| _Self [] [] |.

xaml_slot >> pascal_codes
| Self [95 . Rest] Capitalized |
pascal_codes Self Rest Capitalized.

xaml_slot >> pascal_codes
| Self [First . Rest] [Upper . Capitalized] |
dif First 95,
uppercase_code Self First Upper,
word_codes Self Rest Capitalized.

xaml_slot >> word_codes
| _Self [] [] |.

xaml_slot >> word_codes
| Self [95 . Rest] Capitalized |
pascal_codes Self Rest Capitalized.

xaml_slot >> word_codes
| Self [Code . Rest] [Code . Capitalized] |
dif Code 95,
word_codes Self Rest Capitalized.

xaml_slot >> uppercase_code
  | _Self Lower Upper |
>= Lower 97,
<= Lower 122,
= Upper (- Lower 32).

xaml_slot >> uppercase_code
  | _Self Code Code |
or (< Code 97) (> Code 122).

xaml_slot >> xml_escape
  | Self Raw Text |
string_codes Raw Codes,
xml_codes Self Codes Escaped,
string_codes Text Escaped.

xaml_slot >> xml_codes
| _Self [] [] |.

xaml_slot >> xml_codes
| Self [Code . Rest] [Code . Escaped] |
not (xml_entity Self Code _),
xml_codes Self Rest Escaped.

xaml_slot >> xml_codes
| Self [Code . Rest] Escaped |
xml_entity Self Code Entity,
string_codes Entity Prefix,
concat Prefix Tail Escaped,
xml_codes Self Rest Tail.

xaml_slot >> xml_entity
| _Self 38 "&amp;" |.

xaml_slot >> xml_entity
| _Self 60 "&lt;" |.

xaml_slot >> xml_entity
| _Self 62 "&gt;" |.

xaml_slot >> xml_entity
| _Self 34 "&quot;" |.

xaml_slot >> xml_entity
| _Self 9 "&#9;" |.

xaml_slot >> xml_entity
| _Self 10 "&#10;" |.

xaml_slot >> xml_entity
| _Self 13 "&#13;" |.
