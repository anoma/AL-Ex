@bnf_syntax
#{super => string_syntax, metaclass => grammar}.

bnf_syntax >> document
| Self Input Rest Rules |
sequence Self [rules Rules, blanks] Input Rest.

bnf_syntax >> rules
| _Self Rest Rest [] |.

bnf_syntax >> rules
| Self Input Rest [Rule . Rules] |
sequence Self [rule Rule, more_rules Rules] Input Rest.

bnf_syntax >> more_rules
| _Self Rest Rest [] |.

bnf_syntax >> more_rules
| Self Input Rest [Rule . Rules] |
sequence Self [line_break, rule Rule, more_rules Rules] Input Rest.

bnf_syntax >> rule
| Self Input Rest (rule Name Alternatives) |
sequence Self [nonterminal_name Name, gap, "::=", gap, alternatives Alternatives] Input Rest.

bnf_syntax >> alternatives
| Self Input Rest [Alternative . Alternatives] |
sequence Self [alternative Alternative, more_alternatives Alternatives] Input Rest.

bnf_syntax >> more_alternatives
| _Self Rest Rest [] |.

bnf_syntax >> more_alternatives
| Self Input Rest [Alternative . Alternatives] |
sequence Self [gap, "|", gap, alternative Alternative, more_alternatives Alternatives] Input Rest.

bnf_syntax >> alternative
| Self Input Rest [] |
sequence Self ["\"\""] Input Rest.

bnf_syntax >> alternative
| Self Input Rest [Item . Items] |
sequence Self [item Item, more_items Items] Input Rest.

bnf_syntax >> more_items
| _Self Rest Rest [] |.

bnf_syntax >> more_items
| Self Input Rest [Item . Items] |
sequence Self [gap, item Item, more_items Items] Input Rest.

bnf_syntax >> item
| Self Input Rest (repeat Item) |
sequence Self [simple_item Item, "*"] Input Rest.

bnf_syntax >> item
| Self Input Rest Item |
sequence Self [simple_item Item] Input Rest.

bnf_syntax >> simple_item
| Self Input Rest (any) |
sequence Self ["/./"] Input Rest.

bnf_syntax >> simple_item
| Self Input Rest (nonterminal Name) |
sequence Self [nonterminal_name Name] Input Rest.

bnf_syntax >> simple_item
| Self Input Rest (terminal Terminal) |
sequence Self [expr Terminal] Input Rest.

bnf_syntax >> nonterminal_name
| Self Input Rest Name |
sequence Self [
  where [Name, First, More] {atom_string Name Text, string_codes Text [First . More]},
  "<",
  name_code First,
  zero_or_more name_code More,
  ">"
] Input Rest.

bnf_syntax >> name_code
| _Self [Code . Rest] Rest Code |
{>= Code 97, <= Code 122} ; {>= Code 48, <= Code 57} ; = Code 95.

bnf_syntax >> line_break
| Self Input Rest |
sequence Self [unknown_text, "\n"] Input Rest.

bnf_syntax >> line_break
| Self Input Rest |
sequence Self [known_text, gap] Input Rest.