@propagator
#{
  super => object,
  ivars => [#{name => input_cells}, #{name => output_cell}, #{name => name}]
}.

propagator >> init
| Self Args Self |
get_slots Args #{input_cells => InputCells, output_cell => OutputCell},
set_slots Self #{input_cells => InputCells, name => Self, output_cell => OutputCell},
forall (member InputCells InputCell) (subscribe InputCell Self),
send_async Self cell_updated [none, none].

propagator >> cell_updated
| Self _CellName _Domain |
get_slots Self #{input_cells => InputCells, output_cell => OutputCell},
findall InputDomain InputDomains {member InputCells InputCell, get InputCell domain InputDomain},
same_length InputCells InputDomains,
narrow_output Self InputDomains Candidate,
send_async OutputCell constrain [Candidate].

propagator >> narrow_output
| Self [First . Rest] Candidate |
isa First interval_value,
constrain Self [First . Rest] Candidate.

propagator >> narrow_output
| Self InputDomains Candidate |
findall InputList InputLists {member InputDomains Domain, members Domain InputList},
combos InputLists InputCombos,
findall OutputValue OutputValues {member InputCombos Combo, constrain Self Combo OutputValue},
members Candidate OutputValues.

propagator >> dependents
| Self Dependents |
dependents Self #{} Dependents.

propagator >> dependents
| Self Acc Dependents |
get Acc Self Seen -> = Acc Dependents ; {
  get Self output_cell OutputCell,
  put Acc Self [OutputCell] NewAcc,
  dependents OutputCell NewAcc Dependents
}.