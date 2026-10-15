object >> view
| Self Builder View |
csharp_forward Builder ForwardBuilder,
new ForwardBuilder #{view => "aguil_raw", title => "Raw", target => Self} View.

object >> view
| Self Builder View |
list Builder ListBuilder,
class Self Class,
findall Text Rows {method Class _Name Id, vm_method_source Id _Seq Text _Prov},
new ListBuilder #{
  title => "meta",
  priority => 50,
  items => Rows,
  columns => [#{title => "Body", element => "editor", grammar => "al"}]
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
  columns => [#{element => "text", title => "Class"}]
} View.
