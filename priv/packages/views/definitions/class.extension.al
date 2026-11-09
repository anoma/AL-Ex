class >> class_view
| Self _Builder View |
new phlow_class_methods #{priority => 10, target => Self, title => "Methods"} View.

class >> class_view
| Self _Builder View |
lambda [Source] Read {definition_source Self Source},
new phlow_source #{
  priority => 20,
  source => Read,
  title => "Definition"
} View.

class >> class_view
| Self _Builder View |
lambda [Source] Read {comment_source Self Source},
new phlow_source #{
  priority => 30,
  source => Read,
  title => "Comment"
} View.

class >> method_sources
| Self Filters Sources |
findall Source Sources {
  method_source Self _Method Source Side,
  put Source side Side Candidate,
  forall {member Filters Filter} {accepts Filter Candidate}
}.

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

class >> code_view
| Self View |
new phlow_views #{priority => 20, selector => class_view, target => Self, title => "Code"} View.

class >> method_filter
| Self Filter |
new class_up_to_filter #{
  target => Self,
  side => "instance",
  title => "Instance",
  on_by_default => true
} Filter.

class >> method_filter
| Self Filter |
class Self Meta,
dif Self Meta,
new class_up_to_filter #{
  target => Meta,
  side => "class",
  title => "Class",
  on_by_default => true
} Filter.

class >> method_filter
| _Self Filter |
new filter_text #{} Input,
lambda [Text, Source] Match {
  get Source selector Selector,
  atom_string Selector Name,
  string_codes Name NameCodes,
  string_codes Text TextCodes,
  contains NameCodes TextCodes -> pass
},
new method_filter #{
  title => "Selector",
  input => Input,
  predicate => Match
} Filter.

class >> method_filter
| _Self Filter |
new filter_text #{} Input,
lambda [Text, Source] Match {
  get Source text Contents,
  string_codes Contents ContentCodes,
  string_codes Text TextCodes,
  contains ContentCodes TextCodes -> pass
},
new method_filter #{
  title => "String",
  input => Input,
  predicate => Match
} Filter.

class >> method_source
| Self Method Source "instance" |
reachable_classes [Self] [] Classes,
member Classes Owner,
method_source Owner Method Source.

class >> method_source
| Self Method Source "class" |
class Self Meta,
dif Self Meta,
reachable_classes [Meta] [] Classes,
member Classes Owner,
method_source Owner Method Source.

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