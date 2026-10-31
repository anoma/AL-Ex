@method_source_text
#{
  super => source_text,
  ivars => [#{name => owner}, #{name => selector}, #{name => clauses}]
}.

method_source_text >> current
| Self Source |
get_slots Self #{owner => Owner, target => Method},
method_source Owner Method Source.

method_source_text >> save
| Self Text Edit |
save_definition Self Text Edit.

method_source_text >> validate_definition
| Self Document |
get_slots Self #{owner => Owner, selector => Selector, target => Method},
method Owner Selector Method,
get_slots Document #{header => nil, methods => Methods},
dif Methods [],
forall (member Methods Entry) (get_slots Entry #{owner => Owner, selector => Selector}),
call_next_method Self Document.

method_source_text >> delete
| Self |
get_slots Self #{owner => Owner, selector => Selector, target => Method},
method Owner Selector Method,
vm_retract_method Owner Selector Method,
{method OtherOwner _OtherSelector Method, label OtherOwner} -> pass ; {
  findall Head Heads (clause Method Head _Body),
  forall (member Heads Head) (vm_retract_oapply Method Head),
  vm_retract_class Method behaviour
}.
