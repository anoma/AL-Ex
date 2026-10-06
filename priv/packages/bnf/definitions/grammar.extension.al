grammar >> bnf
| Self Text |
bnf_rules Self Rules,
parse bnf_syntax (document Rules) Text.

grammar >> bnf
| Self Start Text |
bnf_rules Self All,
findall [Name, Alternatives] RulePairs (member All (rule Name Alternatives)),
map_pairs Index RulePairs,
reachable_indexed Self Index [Start] #{} Reachable,
findall (rule Name Alternatives) Rules {member All (rule Name Alternatives), get Reachable Name true},
parse bnf_syntax (document Rules) Text.

grammar >> write_bnf
| Self Start Path Effect |
bnf Self Start Text,
string_codes Text Codes,
concat Codes [10] Line,
string_codes Contents Line,
new effect #{arguments => [Path, Contents], operation => write, provider => file} Effect.

grammar >> reachable
| _Self _Rules [] Seen Seen |.

grammar >> reachable
| Self Rules [Name . Names] Seen Reached |
member Seen Name -> reachable Self Rules Names Seen Reached ; {referenced Self Rules Name Referenced, concat Names Referenced Next, concat Seen [Name] Marked, reachable Self Rules Next Marked Reached}.

grammar >> reachable_indexed
| _Self _Index [] Seen Seen |.

grammar >> reachable_indexed
| Self Index [Name . Names] Seen Reached |
get Seen Name true -> reachable_indexed Self Index Names Seen Reached ; {get Index Name [] Alternatives, findall Other Referenced {member Alternatives Alternative, member Alternative Item, = Item (nonterminal Other) ; = Item (repeat (nonterminal Other))}, concat Referenced Names Next, put Seen Name true Marked, reachable_indexed Self Index Next Marked Reached}.

grammar >> referenced
| _Self Rules Name Referenced |
findall Other Referenced {member Rules (rule Name Alternatives), member Alternatives Alternative, member Alternative Item, = Item (nonterminal Other) ; = Item (repeat (nonterminal Other))}.

grammar >> bnf_rules
| Self Rules |
precedence Self Order,
findall Name Names {member Order Class, class Class grammar, dif Class syntax, method Class Name _},
ground Names -> distinct_ground Self Names Unique ; distinct Self Names [] Unique,
rules_for Self Order Unique Rules.

grammar >> distinct
| _Self [] Seen Seen |.

grammar >> distinct
| Self [Item . Items] Seen Unique |
member Seen Item -> distinct Self Items Seen Unique ; {concat Seen [Item] Next, distinct Self Items Next Unique}.

grammar >> distinct_ground
| Self Items Unique |
distinct_ground_items Self Items [] Unique [].

grammar >> distinct_ground_items
| _Self [] _Seen Tail Tail |.

grammar >> distinct_ground_items
| Self [Item . Items] Seen Unique Tail |
member Seen Item -> distinct_ground_items Self Items Seen Unique Tail ; {= Unique [Item . Rest], distinct_ground_items Self Items [Item . Seen] Rest Tail}.

grammar >> rules_for
| _Self _Order [] [] |.

grammar >> rules_for
| Self Order [Name . Names] [(rule Name Alternatives) . Rules] |
alternatives Self Order Name All,
ground All -> distinct_ground Self All Alternatives ; distinct Self All [] Alternatives,
rules_for Self Order Names Rules.

grammar >> alternatives
| _Self [] _Name [] |.

grammar >> alternatives
| Self [Class . Classes] Name Alternatives |
method Class Name Id -> {findall [Head, Body] Clauses (clause Id Head Body), bodies_alternatives Self Classes Name Clauses Alternatives} ; alternatives Self Classes Name Alternatives.

grammar >> bodies_alternatives
| _Self _Classes _Name [] [] |.

grammar >> bodies_alternatives
| Self Classes Name [[[Receiver, Input . _Arguments], Body] . Clauses] Alternatives |
terminal_items Self Input Prefix,
body_items Self Receiver Body BodyItems,
concat Prefix BodyItems Items,
member Items written -> = Expanded [] ; findall Alternative Expanded {splice Self Classes Name Items Alternative},
bodies_alternatives Self Classes Name Clauses Others,
concat Expanded Others Alternatives.

grammar >> splice
| _Self _Classes _Name [] [] |.

grammar >> splice
| Self Classes Name [next . Items] Alternative |
alternatives Self Classes Name Parents,
member Parents Parent,
splice Self Classes Name Items Rest,
concat Parent Rest Alternative.

grammar >> splice
| Self Classes Name [Item . Items] [Item . Rest] |
dif Item next,
splice Self Classes Name Items Rest.

grammar >> body_items
| _Self _Receiver [] [] |.

grammar >> body_items
| Self Receiver [Goal . Goals] Items |
functor Goal Name Args,
goal_items Self Receiver Name Args GoalItems,
body_items Self Receiver Goals More,
concat GoalItems More Items.

grammar >> goal_items
| Self _Receiver match_pattern [_Grammar, Pattern, _Input, _Rest] Items |
pattern_items Self Pattern Items.

grammar >> goal_items
| Self _Receiver sequence [_Grammar, Patterns, _Input, _Rest] Items |
patterns_items Self Patterns Items.

grammar >> goal_items
| _Self _Receiver call_next_method _Args [next] |.

grammar >> goal_items
| Self Receiver send [Grammar, Name, Message] Items |
{== Grammar Receiver, = Message [_Input, _Rest . Arguments]} -> call_items Self Name Arguments Items ; = Items [].

grammar >> goal_items
| Self _Receiver = [_Input, Expected] Items |
terminal_items Self Expected Items.

grammar >> goal_items
| _Self _Receiver var _Args [written] |.

grammar >> goal_items
| _Self _Receiver Name _Args [] |
dif Name match_pattern,
dif Name sequence,
dif Name call_next_method,
dif Name send,
dif Name =,
dif Name var.

grammar >> call_items
| Self Name Arguments Items |
= Arguments [] -> atom_items Self Name Items ; compound_items Self Name Arguments Items.

grammar >> terminal_items
| Self Expected Items |
list_prefix Self Expected Tokens,
= Tokens [] -> = Items [] ; {ground Tokens, string_codes Text Tokens} -> = Items [(terminal Text)] ; findall Item Items {member Tokens Token, token_item Self Token Item}.

grammar >> list_prefix
| Self List Tokens |
var List -> = Tokens [] ; = List [Token . Rest] -> {list_prefix Self Rest More, = Tokens [Token . More]} ; = Tokens [].

grammar >> patterns_items
| _Self [] [] |.

grammar >> patterns_items
| Self [Pattern . Patterns] Items |
pattern_items Self Pattern First,
patterns_items Self Patterns More,
concat First More Items.

grammar >> pattern_items
| Self Pattern Items |
atom Pattern -> atom_items Self Pattern Items ; class Pattern string -> = Items [(terminal Pattern)] ; class Pattern list -> findall Item Items {member Pattern Token, token_item Self Token Item} ; {functor Pattern Name Args, compound_items Self Name Args Items}.

grammar >> token_item
| _Self Token (terminal Token) |
ground Token,
atom Token ; class Token string ; class Token number.

grammar >> token_item
| _Self Token (any) |
not {ground Token, atom Token ; class Token string ; class Token number}.

grammar >> atom_items
| _Self next [next] |.

grammar >> atom_items
| _Self known_text [] |.

grammar >> atom_items
| _Self unknown_text [written] |.

grammar >> atom_items
| _Self Name [(nonterminal Name)] |
dif Name next,
dif Name known_text,
dif Name unknown_text.

grammar >> compound_items
| _Self zero_or_more [Pattern, _Values] [(repeat (nonterminal Pattern))] |.

grammar >> compound_items
| _Self code _Args [(any)] |.

grammar >> compound_items
| _Self next _Args [next] |.

grammar >> compound_items
| _Self where _Args [] |.

grammar >> compound_items
| _Self within _Args [] |.

grammar >> compound_items
| _Self unless _Args [] |.

grammar >> compound_items
| _Self Name _Args [(nonterminal Name)] |
dif Name zero_or_more,
dif Name code,
dif Name next,
dif Name where,
dif Name within,
dif Name unless.

grammar >> precedence
| Self Order |
reachable_classes [Self] [] Classes,
linearize Self [Self] Classes Order.

grammar >> linearize
| _Self [] _Remaining [] |.

grammar >> linearize
| Self [Class . Ready] Remaining [Class . Order] |
findall Other Left {member Remaining Other, dif Other Class},
findall Super Newly {super Class Super, member Left Super, not {member Left Sub, super Sub Super}},
concat Newly Ready Next,
linearize Self Next Left Order.
