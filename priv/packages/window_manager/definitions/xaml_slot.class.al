@xaml_slot
#{super => value, ivars => [#{name => owner}, #{name => spec}]}.

xaml_slot >> xaml_property
  | Self Text |
get_slots Self #{owner => Owner},
xaml_tag Owner Tag,
xaml_name Self Name,
to_xaml Self Content,
format "<~a.~a>~a</~a.~a>" [Tag, Name, Content, Tag, Name] Text.

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
get_slots Self #{spec => Spec},
not (get Spec xaml_name _),
get_slots Spec #{name => Slot},
atom_string Slot Raw,
pascal_case Self Raw Name.

xaml_slot >> pascal_case
  | Self Raw Name |
split Raw "_" Words,
lambda [Word, Capitalized] Capitalize {capitalize_word Self Word Capitalized},
map Words Capitalize CapitalizedWords,
join CapitalizedWords Name.

xaml_slot >> capitalize_word
  | _Self "" "" |.

xaml_slot >> capitalize_word
  | Self Word Capitalized |
string_codes Word [First . Rest],
uppercase_code Self First Upper,
string_codes Capitalized [Upper . Rest].

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
lambda [Code, Part] Escape {
  xml_character Self Code Part
},
map Codes Escape Parts,
join Parts Text.

xaml_slot >> xml_character
  | Self Code Text |
xml_entity Self Code Text.

xaml_slot >> xml_character
  | Self Code Text |
not (xml_entity Self Code _),
string_codes Text [Code].

xaml_slot >> xml_entity
  | _Self Code Text |
get #{
  38 => "&amp;",
  60 => "&lt;",
  62 => "&gt;",
  34 => "&quot;",
  9 => "&#9;",
  10 => "&#10;",
  13 => "&#13;"
} Code Text.