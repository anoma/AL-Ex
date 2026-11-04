object >> view
| Self Builder View |
raw Builder RawBuilder,
new RawBuilder #{target => Self, title => "Raw"} View.

object >> view
| Self _Builder View |
code_view Self View.

object >> view
| Self Builder View |
list Builder ListBuilder,
class Self Class,
lambda [X, Res] ToEntry (= Res #{target => X, text => X}),
reachable_classes [Class] [] InheritanceChain,
map InheritanceChain ToEntry Entries,
new ListBuilder #{
  columns => [#{cell => brick_text, header => "Class"}],
  items => Entries,
  priority => 30,
  title => "Inheritance"
} View.

object >> code_view
| Self View |
class Self Class,
new phlow_views #{priority => 50, selector => class_view, target => Class, title => "Code"} View.
