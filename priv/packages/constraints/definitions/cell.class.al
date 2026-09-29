@cell
#{super => object, ivars => [#{name => subscribers}, #{name => domain}, #{name => name}]}.

cell >> init
| Self Args Self |
set_slots Self #{name => Self, subscribers => []}.

cell >> constrain
| Self Candidate |
get Self domain OldDomain -> {
  intersection OldDomain Candidate NewDomain,
  == NewDomain OldDomain -> pass ; {set_slot Self domain NewDomain, notify Self NewDomain}
} ; {set_slot Self domain Candidate, notify Self Candidate}.

cell >> notify
| Self Domain |
forall {get Self subscribers Subscribers, member Subscribers Subscriber} (send_async Subscriber cell_updated [Self, Domain]),
cut.

cell >> subscribe
| Self Subscriber |
get Self subscribers Subscribers,
set_slot Self subscribers [Subscriber . Subscribers].

cell >> dependents
| Self Dependents |
dependents Self #{} Dependents.

cell >> dependents
| Self Acc Dependents |
get Acc Self Seen -> = Acc Dependents ; {
  get Self subscribers Subscribers,
  put Acc Self Subscribers NewAcc,
  dependents Self NewAcc Subscribers Dependents
}.

cell >> dependents
| Self Acc [] Acc |.

cell >> dependents
| Self Acc [Subscriber . Subscribers] Dependents |
dependents Subscriber Acc NewAcc,
dependents Self NewAcc Subscribers Dependents.