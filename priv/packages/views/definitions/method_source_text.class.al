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
get_slots Self #{
  owner => Owner,
  selector => Selector,
  target => Method,
  clauses => OriginalClauses
},
method Owner Selector Method,
get_slots Document #{header => nil, methods => Methods},
dif Methods [],
forall {member Methods Entry} {get_slots Entry #{owner => Owner, selector => Selector}},
findall Clause CurrentClauses {
  vm_method_source Method Sequence Text Provenance,
  = Clause #{provenance => Provenance, sequence => Sequence, text => Text}
},
= OriginalClauses CurrentClauses.

method_source_text >> delete
| Self |
get_slots Self #{owner => Owner, selector => Selector, target => Method},
method Owner Selector Method,
vm_retract_method Owner Selector Method,
{method OtherOwner _OtherSelector Method, label OtherOwner} -> pass ; {
  findall Head Heads (clause Method Head _Body),
  forall {member Heads Head} {vm_retract_oapply Method Head},
  vm_retract_class Method behaviour
}.

method_source_text >> package
| Self Package |
get_slots Self #{owner => Owner, selector => Selector},
active_package package_manager Package Build,
adds_method Build Owner Selector.

method_source_text >> package
| Self Package |
get_slots Self #{owner => Owner, selector => Selector},
not {active_package package_manager _Other OtherBuild, adds_method OtherBuild Owner Selector},
active_package package_manager Package Build,
originates_class Build Owner.

method_source_text >> package_candidate
| Self Package |
get Self owner Owner,
not {active_package package_manager _Origin OriginBuild, originates_class OriginBuild Owner},
active_package package_manager Package _Build.

method_source_text >> package_candidate
| Self Package |
get Self owner Owner,
active_package package_manager _Origin OriginBuild,
originates_class OriginBuild Owner,
active_package package_manager Package Build,
includes_build Build OriginBuild -> pass.

method_source_text >> set_package
| Self Package |
get_slots Self #{owner => Owner, selector => Selector, target => Method},
method Owner Selector Method,
package_candidate Self Package,
findall Build Builds {active_package package_manager _Other Build, adds_method Build Owner Selector},
forall {member Builds Build} {
  set_slot Build status open,
  added_methods Build Methods,
  findall Entry Retained {member Methods Entry, dif Entry [Owner, Selector]},
  set_slot Build added_methods Retained
},
active_build Package Destination,
set_slot Destination status open,
include_method Destination Owner Selector.
