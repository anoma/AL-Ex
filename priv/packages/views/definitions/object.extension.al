object >> view
| Self Builder View |
raw Builder RawBuilder,
new RawBuilder #{title => "Raw", target => Self} View.

object >> view
| Self Builder View |
list Builder ListBuilder,
class Self Class,
findall Text Rows {method Class _Name Id, vm_method_source Id _Seq Text _Prov},
new ListBuilder #{
  title => "meta",
  priority => 50,
  row_spacing => 8,
  items => Rows,
  columns => [#{header => "Body", cell => brick_editor_cell, grammar => "al"}]
} View.

object >> view
| Self Builder View |
list Builder ListBuilder,
class Self Class,
lambda [X, Res] ToEntry {= Res #{text => X, target => X}},
reachable_classes [Class] [] InheritanceChain,
map InheritanceChain ToEntry Entries,
new ListBuilder #{
  title => "Inheritance",
  priority => 30,
  items => Entries,
  columns => [#{header => "Class", cell => brick_text}]
} View.