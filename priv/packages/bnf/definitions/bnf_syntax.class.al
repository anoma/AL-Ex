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
= After_2 [58, 58, 61 . Inner],
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
= After [124 . Inner],
send Grammar gap [Inner, After_2],
send Grammar alternative [After_2, After_3, Alternative],
send Grammar more_alternatives [After_3, Rest, Alternatives].

bnf_syntax >> alternative
| Grammar Input Rest [] |
= Input [34, 34 . Rest].

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
= After [42 . Rest].

bnf_syntax >> item
| Grammar Input Rest Item |
send Grammar simple_item [Input, Rest, Item].

bnf_syntax >> simple_item
| Grammar Input Rest (any) |
= Input [47, 46, 47 . Rest].

bnf_syntax >> simple_item
| Grammar Input Rest (nonterminal Name) |
send Grammar nonterminal_name [Input, Rest, Name].

bnf_syntax >> simple_item
| Grammar Input Rest (terminal Terminal) |
send Grammar expr [Input, Rest, Terminal].

bnf_syntax >> nonterminal_name
| Grammar Input Rest Name |
not (var Input),
= Input [60 . Inner],
send Grammar name_code [Inner, After, First],
send Grammar zero_or_more [After, After_2, name_code, More],
= After_2 [62 . Rest],
call [Name, First, More] {atom_string Name Text, string_codes Text [First . More]} [Name, First, More].

bnf_syntax >> nonterminal_name
| Grammar Input Rest Name |
var Input,
call [Name, First, More] {atom_string Name Text, string_codes Text [First . More]} [Name, First, More],
= Input [60 . Inner],
send Grammar name_code [Inner, After, First],
send Grammar zero_or_more [After, After_2, name_code, More],
= After_2 [62 . Rest].

bnf_syntax >> name_code
| _Self [Code . Rest] Rest Code |
{>= Code 97, <= Code 122} ; {>= Code 48, <= Code 57} ; = Code 95.

bnf_syntax >> line_break
| Grammar Input Rest |
var Input,
= Input [10 . Rest].

bnf_syntax >> line_break
| Grammar Input Rest |
not (var Input),
send Grammar gap [Input, Rest].