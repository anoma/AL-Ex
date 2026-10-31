class >> view
| Self _Builder View |
new phlow_views #{priority => 20, selector => class_view, target => Self, title => "Code"} View.

class >> view
| Self Builder View |
call_next_method Self Builder View.

class >> class_view
| Self _Builder View |
new phlow_class_methods #{priority => 10, target => Self, title => "Methods"} View.

class >> class_view
| Self _Builder View |
new phlow_class_source #{
  priority => 20,
  source_selector => definition_source,
  target => Self,
  title => "Definition"
} View.

class >> class_view
| Self _Builder View |
new phlow_class_source #{
  priority => 30,
  source_selector => comment_source,
  target => Self,
  title => "Comment"
} View.

class >> class_filters
| Self [Filter] |
new class_up_to_filter #{target => Self} Filter.

class >> method_sources
| Self Filters Sources |
reachable_classes [Self] [] Classes,
findall Source Sources {
  member Classes Owner,
  forall (member Filters Filter) (accepts Filter Owner),
  method_source Owner _Method Source
}.

class >> method_source
| Self Method Source |
method Self Selector Method,
findall Clause Clauses {
  vm_method_source Method Sequence Text Provenance,
  = Clause #{provenance => Provenance, sequence => Sequence, text => Text}
},
lambda [Tail, Clause, Combined] Body {
  get Clause text Part,
  = Tail "" -> = Combined Part ; format "~a~%~%~a" [Part, Tail] Combined
},
fold_right Clauses Body "" Text,
atom_string Self OwnerName,
atom_string Selector MethodName,
format "~a >> ~a" [OwnerName, MethodName] Label,
new method_source_text #{
  clauses => Clauses,
  label => Label,
  owner => Self,
  selector => Selector,
  target => Method,
  text => Text
} Source.

class >> definition_source
| Self Source |
findall Super Supers (super Self Super),
get Self ivars Ivars -> pass ; = Ivars [],
class Self Meta,
print_object #{ivars => Ivars, metaclass => Meta, super => Supers} Spec,
format "@~a~%~a." [Self, Spec] Text,
format "~a" [Self] Label,
new class_source_text #{
  label => Label, target => Self, text => Text, source_selector => definition_source
} Source.

class >> comment_source
| Self Source |
get Self comment Text -> pass ; = Text "",
format "~a comment" [Self] Label,
new class_source_text #{
  grammar => "", label => Label, target => Self, text => Text, source_selector => comment_source
} Source.
