@bnf_syntax
#{super => string_syntax, metaclass => grammar}.

bnf_syntax >> document
| Grammar Input Rest Rules |
send Grammar rules [Input, After, Rules],
send Grammar blanks [After, Rest].

bnf_syntax >> rules
| Grammar Rest Rest [] |.

bnf_syntax >> rules
| Grammar Input Rest [Rule . Rules] |
send Grammar rule [Input, After, Rule],
send Grammar more_rules [After, Rest, Rules].

bnf_syntax >> more_rules
| Grammar Rest Rest [] |.

bnf_syntax >> more_rules
| Grammar Input Rest [Rule . Rules] |
send Grammar line_break [Input, After],
send Grammar rule [After, After_2, Rule],
send Grammar more_rules [After_2, Rest, Rules].

bnf_syntax >> rule
| Grammar Input Rest (rule Name Alternatives) |
send Grammar nonterminal_name [Input, After, Name],
send Grammar gap [After, After_2],
vm_text_concat "::=" Inner After_2,
send Grammar gap [Inner, After_3],
send Grammar alternatives [After_3, Rest, Alternatives].

bnf_syntax >> alternatives
| Grammar Input Rest [Alternative . Alternatives] |
send Grammar alternative [Input, After, Alternative],
send Grammar more_alternatives [After, Rest, Alternatives].

bnf_syntax >> more_alternatives
| Grammar Rest Rest [] |.

bnf_syntax >> more_alternatives
| Grammar Input Rest [Alternative . Alternatives] |
send Grammar gap [Input, After],
vm_text_concat "|" Inner After,
send Grammar gap [Inner, After_2],
send Grammar alternative [After_2, After_3, Alternative],
send Grammar more_alternatives [After_3, Rest, Alternatives].

bnf_syntax >> alternative
| Grammar Input Rest [] |
vm_text_concat "\"\"" Rest Input.

bnf_syntax >> alternative
| Grammar Input Rest [Item . Items] |
send Grammar item [Input, After, Item],
send Grammar more_items [After, Rest, Items].

bnf_syntax >> more_items
| Grammar Rest Rest [] |.

bnf_syntax >> more_items
| Grammar Input Rest [Item . Items] |
send Grammar gap [Input, After],
send Grammar item [After, After_2, Item],
send Grammar more_items [After_2, Rest, Items].

bnf_syntax >> item
| Grammar Input Rest (repeat Item) |
send Grammar simple_item [Input, After, Item],
vm_text_concat "*" Rest After.

bnf_syntax >> item
| Grammar Input Rest Item |
send Grammar simple_item [Input, Rest, Item].

bnf_syntax >> simple_item
| Grammar Input Rest (any) |
vm_text_concat "/./" Rest Input.

bnf_syntax >> simple_item
| Grammar Input Rest (nonterminal Name) |
send Grammar nonterminal_name [Input, Rest, Name].

bnf_syntax >> simple_item
| Grammar Input Rest (terminal Terminal) |
send Grammar expr [Input, Rest, Terminal].

bnf_syntax >> nonterminal_name
| Grammar Input Rest Name |
vm_text_concat "<" Inner Input,
atom_string Name Text,
text Grammar Inner After name_char name_char Text,
vm_text_concat ">" Rest After.

bnf_syntax >> name_char
| Self Input Rest Char |
word_char Self Input Rest Char.

bnf_syntax >> name_char
| _Self [Char . Rest] Rest Char |
in_domain Char ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"].

bnf_syntax >> name_char
| _Self ["_" . Rest] Rest "_" |.

bnf_syntax >> line_break
| Grammar Input Rest |
var Input,
vm_text_concat "\n" Rest Input.

bnf_syntax >> line_break
| Grammar Input Rest |
not (var Input),
send Grammar gap [Input, Rest].