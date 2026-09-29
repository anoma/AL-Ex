defprogram bootstrap #{deps: [], version: 25}.

vm_set_class class class.
vm_set_class object class.
vm_set_class behaviour class.
vm_set_super class object.
vm_set_super behaviour object.
vm_set_method object meta metaclass.
vm_set_method object defmethod defmethod.
vm_set_class metaclass behaviour.
vm_set_oapply metaclass [Self, Class, Meta] {class Self Class, class Class Meta}.
vm_set_class defmethod behaviour.
vm_set_oapply defmethod [Self, MethodName, Head, Body] {
  vm_assert_valid_clause_self Self Head,
  method Self MethodName Impl -> vm_set_oapply Impl Head Body ; {
    vm_fresh_id Impl,
    vm_set_method Self MethodName Impl,
    vm_set_class Impl behaviour,
    vm_set_oapply Impl Head Body
  }
}.
vm_set_class clear_method behaviour.
vm_set_oapply clear_method [Self, MethodName] {
  forall {method Self MethodName Impl} {
    findall Head Heads {clause Impl Head _},
    forall {member Heads Head} {vm_retract_oapply Impl Head}
  }
}.

object >> does_not_understand
| Self Method Args |
fail.

object >> between
| _Self Low High Low |
Low <= High.

object >> between
| Self Low High Value |
Low < High,
Next = Low + 1,
between Self Next High Value.

object >> reorder_clauses
| Self MethodName Left Right |
method Self MethodName MethodObject,
findall [Head, Body] Left {clause MethodObject Head Body},
forall {member Left [Head, _]} {vm_retract_oapply MethodObject Head},
forall {member Right [Head, Body]} {vm_set_oapply MethodObject Head Body}.

object >> print_object
| Self ClassName |
class Self ClassName.

behaviour >> print_object
| Self Text |
vm_method_source Self _Seq Text _Provenance.

object >> listing
| Class Name |
method Class Name Impl,
forall {print_object Impl Text} {vm_format "~a~%~%" [Text]}.

object >> get
| Self Key Value |
slot Self Key Value.

object >> ivar_name
| _Self Spec Name |
isa Spec map,
get Spec name Name.

object >> validate_ivar_domain
| _Self Spec Value |
get Spec domain Domain,
in_domain Value Domain.

object >> validate_ivar_domain
| _Self Spec _Value |
not {get Spec domain _}.

object >> validate_ivar_type
| _Self Spec Value |
get Spec type Type,
isa Value Type.

object >> validate_ivar_type
| _Self Spec _Value |
not {get Spec type _}.

object >> validate_ivar_spec
| Self Spec Name Value |
ivar_name Self Spec Name,
validate_ivar_domain Self Spec Value,
validate_ivar_type Self Spec Value.

object >> validate_slot
| Self _Key _Value |
class Self object.

object >> validate_slot
| Self Key Value |
not {class Self object},
vm_cached_find_ivar_spec Self Key Spec,
not {Spec = no_spec},
validate_ivar_spec Self Spec Key Value.

class >> validate_slot
| _Self _Key _Value |.

category >> validate_slot
| _Self _Key _Value |.

behaviour >> validate_slot
| _Self _Key _Value |.

object >> set_slot
| Self Key Value |
validate_slot Self Key Value,
vm_set_slot Self Key Value.

object >> set_slots
| Self Slots |
forall {get Slots Key Value} {set_slot Self Key Value}.

object >> get_slots
| Self Requested |
findall Key Keys {get Requested Key _},
slots Self Keys Requested.

object >> slots
| Self [] #{} |.

object >> slots
| Self [SlotName . SlotNames] M |
slots Self SlotNames M1,
get Self SlotName SlotVal,
vm_map_put M1 SlotName SlotVal M.

object >> slot_history
| Self Key Values |
findall V RawValues {vm_slot_at Self Key V _T},
dedupe RawValues Values.

vm_set_class map class.

map >> get
| Self Key Value |
vm_map_get Self Key Value.

map >> get
| Self Key _Default Value |
vm_map_get Self Key Value.

map >> get
| Self Key Default Default |
not {vm_map_get Self Key _}.

map >> put
| Self Key Value Updated |
vm_map_put Self Key Value Updated.

map >> put_new
| Self Key _Default Self |
get Self Key _Value.

map >> put_new
| Self Key Default Updated |
not {get Self Key _Value},
put Self Key Default Updated.

object >> get_optional
| Self Key Value |
get Self Key Value.

object >> get_optional
| Self Key _Value |
not {get Self Key _}.

object >> retract_existing_facts
| Self |
retract_declaration Self,
findall [N, Id] ExistingMethods {method Self N Id},
forall {member ExistingMethods [N, Id]} {vm_retract_method Self N Id}.

object >> retract_declaration
| Self |
findall C ExistingClasses {class Self C},
forall {member ExistingClasses C} {vm_retract_class Self C},
findall S ExistingSupers {super Self S},
forall {member ExistingSupers S} {vm_retract_super Self S},
findall K ExistingAosKeys {slot Self K _},
vm_cached_ivar_specs Self IvarSpecs,
ivar_names IvarSpecs DeclaredNames,
findall K ExistingSoaKeys {member DeclaredNames K, slot Self K _ soa},
concat ExistingAosKeys ExistingSoaKeys ExistingSlotKeys,
forall {member ExistingSlotKeys K} {vm_retract_slot Self K}.

object >> claim_name
| Self Name |
class Name _ -> retract_declaration Name ; pass.

class >> construct
| Self #{class: Self} |.

vm_set_method class allocate allocate_class.
vm_set_class allocate_class behaviour.
vm_set_oapply allocate_class [Self, Args, Name] {
  get Args name Name,
  get Args super object Super,
  get Args ivars [] Ivars,
  ivar_names Ivars _,
  class Self Meta,
  class Name _ -> {
    findall S OldSupers {super Name S},
    slot Name ivars OldIvars,
    Existed = true
  } ; {OldSupers = [], OldIvars = [], Existed = false},
  claim_name Self Name,
  vm_set_class Name Meta,
  set_supers Name Super,
  set_slot Name ivars Ivars,
  Existed = true -> {
    findall S NewSupers {super Name S},
    class_redefined Name #{ivars: OldIvars, supers: OldSupers} #{ivars: Ivars, supers: NewSupers}
  } ; pass
}.

list >> ivar_names
| [] [] |.

list >> ivar_names
| [Spec . Rest] [Name . Names] |
ivar_name object Spec Name,
ivar_names Rest Names.

class >> class_redefined
| Self OldSpec NewSpec |
get OldSpec ivars OldIvars,
get NewSpec ivars NewIvars,
ivar_names OldIvars OldNames,
ivar_names NewIvars NewNames,
findall Spec AddedSpecs {
  member NewIvars Spec,
  ivar_name object Spec Name,
  not {member OldNames Name}
},
findall Name RemovedNames {member OldNames Name, not {member NewNames Name}},
findall O Instances {isa O Self, label O},
forall {member Instances O} {reconcile_redefined_instance O AddedSpecs RemovedNames}.

class >> delete_class
| Self |
findall S OldSupers {super Self S},
slot Self ivars OldIvars,
class_redefined Self #{ivars: OldIvars, supers: OldSupers} #{ivars: [], supers: []},
retract_existing_facts Self.

object >> reconcile_redefined_instance
| Self AddedSpecs RemovedNames |
forall {member RemovedNames Key} {vm_retract_slot Self Key},
forall {member AddedSpecs Spec} {backfill_ivar Self Spec}.

object >> backfill_ivar
| Self Spec |
get Spec name Name,
get Spec default Default,
set_slot Self Name Default.

object >> backfill_ivar
| _Self Spec |
not {get Spec default _Default}.

object >> set_supers
| Name Super |
class Super list,
set_super_list Name Super.

object >> set_supers
| Name Super |
not {class Super list},
vm_set_super Name Super.

object >> set_super_list
| _Name [] |.

object >> set_super_list
| Name [S . Rest] |
vm_set_super Name S,
set_super_list Name Rest.

object >> allocate
| Self Args Name |
class Self Meta,
get Args name Name -> claim_name Self Name ; gensym Name,
vm_set_class Name Meta.

object >> init
| Self Args Self |
vm_cached_ivar_specs Self IvarSpecs,
build_durable_slots Self Self Args IvarSpecs Slots,
set_slots Self Slots.

list >> collect_ivar_specs
| [] [] |.

list >> collect_ivar_specs
| [C . Rest] Specs |
collect_ivar_specs Rest RestSpecs,
slot C ivars OwnSpecs,
concat OwnSpecs RestSpecs Specs.

list >> collect_ivar_specs
| [C . Rest] RestSpecs |
collect_ivar_specs Rest RestSpecs,
not {slot C ivars _}.

object >> build_durable_slots
| _Self _Class _Args [] #{} |.

object >> build_durable_slots
| Self Class Args [Spec . Rest] Output |
build_durable_slots Self Class Args Rest Partial,
apply_ivar_spec Self Args Spec Name Value,
include_durable_slot Partial Name Value Output.

object >> include_durable_slot
| Partial Name Value Output |
ground Value,
vm_map_put Partial Name Value Output.

object >> include_durable_slot
| Partial Name Value Output |
not {ground Value},
class Value anonymous_method,
get Value args Args,
ground Args,
vm_map_put Partial Name Value Output.

object >> include_durable_slot
| Partial _Name Value Partial |
not {ground Value},
not {class Value anonymous_method, get Value args Args, ground Args}.

class >> init
| Self _ Self |.

class >> new
| Self Args New |
construct Self Construct,
allocate Construct Args Alloc,
init Alloc Args New.

class >> new
| Self New |
new Self #{} New.

new class #{ivars: [], name: category, super: object} _.

object >> copy_methods
| _Self [] |.

object >> copy_methods
| Self [[Name, Id] . Rest] |
vm_set_method Self Name Id,
copy_methods Self Rest.

object >> import
| Self Category |
findall [Name, Id] Pairs {method Category Name Id},
copy_methods Self Pairs.

new class #{ivars: [], name: value, super: object} _.

value >> allocate
| Self _ Self |.

value >> put
| Self Key Value Updated |
vm_map_put Self Key Value Updated.

value >> put_slots
| Self [] Self |.

value >> put_slots
| Self [[Key, Value] . Rest] Updated |
put Self Key Value Partial,
put_slots Partial Rest Updated.

value >> init
| Self Args Output |
vm_map_get Self class Class,
reachable_classes [Class] [] Chain,
collect_ivar_specs Chain IvarSpecs,
init_value Self Class Args IvarSpecs Output.

object >> init_value
| _Self Class _Args [] Output |
isa Output Class.

object >> init_value
| Self Class Args [Spec . Rest] Output |
build_from_ivar_specs Self Class Args [Spec . Rest] Output.

object >> apply_ivar_spec
| Self Args Spec Name Value |
validate_ivar_spec Self Spec Name Value,
{not {get Args Name _}, get Spec default Default} -> Value = Default ; pass,
get_optional Args Name Value.

object >> build_from_ivar_specs
| Self Class Args [] #{class: Class} |.

object >> build_from_ivar_specs
| Self Class Args [Spec . Rest] Output |
build_from_ivar_specs Self Class Args Rest Partial,
apply_ivar_spec Self Args Spec Name Value,
vm_map_put Partial Name Value Output.

vm_set_super map object.
vm_set_class defclass behaviour.
vm_set_oapply defclass [Name, Metaclass, Super, Ivars, Categories] {
  new Metaclass #{ivars: Ivars, name: Name, super: Super} _,
  forall {member Categories Category} {import Name Category}
}.
vm_set_class extend_class behaviour.
vm_set_oapply extend_class [Name, Supers] {forall {member Supers S} {super Name S -> pass ; vm_set_super Name S}}.

object >> examine
| Self #{
  class_supers: ClassSupers,
  classes: Classes,
  clauses: Clauses,
  direct_slots: DirectSlots,
  id: Self,
  methods: Methods,
  objects: Objects,
  providers: Providers,
  subs: Subs,
  supers: Supers
} |
findall C Classes {class Self C},
findall [C, S] ClassSupers {class Self C, super C S},
findall C Objects {isa C Self, label C},
findall S Supers {super Self S},
findall Sub Subs {super Sub Self},
findall [N, Id] Methods {method Self N Id},
findall [Provider, N] Providers {method Provider N Self, label Provider},
findall [Head, Body] Clauses {clause Self Head Body},
findall [SlotName, SlotValue] DirectSlots {slot Self SlotName SlotValue}.

new class #{
  ivars: [#{name: name}, #{name: version}, #{name: deps}, #{name: tx}],
  name: program_execution,
  super: object
} _.
new class #{
  ivars: [#{name: tx}, #{name: branch}, #{name: status}, #{name: reason}],
  name: transaction,
  super: object
} _.
new class #{
  ivars: [#{name: effect}, #{name: head}, #{name: goals}, #{name: status}],
  name: future_transaction,
  super: object
} _.

future_transaction >> init
| Self Args Self |
get_slots Args #{effect: Effect, goals: Goals, head: Head, status: Status},
set_slots Self #{effect: Effect, goals: Goals, head: Head, status: Status}.

future_transaction >> run
| Self |
get Self status ready,
run_goals Self [].

future_transaction >> run
| Self |
get Self status waiting,
get Self effect Effect,
get Effect status completed,
get Effect outcome Outcome,
run_goals Self [Outcome].

future_transaction >> run_goals
| Self Arguments |
get_slots Self #{goals: Goals, head: Head},
set_slot Self status running,
call Head Goals Arguments,
set_slot Self status completed.

new class #{
  ivars: [
    #{name: provider},
    #{name: operation},
    #{name: arguments},
    #{name: status},
    #{name: outcome},
    #{name: requested_by},
    #{name: completed_by}
  ],
  name: effect,
  super: object
} _.

effect >> init
| Self Args Self |
get Args provider Provider,
get Args operation Operation,
get Args arguments Arguments,
vm_transaction_object RequestedBy,
set_slots Self #{
  arguments: Arguments,
  completed_by: none,
  operation: Operation,
  outcome: none,
  provider: Provider,
  requested_by: RequestedBy,
  status: pending
},
vm_emit_effect Self Provider Operation Arguments.

effect >> complete
| Self Outcome |
get Self status pending,
vm_transaction_object CompletedBy,
set_slots Self #{completed_by: CompletedBy, outcome: Outcome, status: completed}.

transaction >> listing
| Self Text |
get Self tx Tx,
vm_transaction_source Tx Text _Origin.

program_execution >> init
| Self Args Self |
get Args name Name,
get Args version Version,
get Args deps Deps,
vm_current_tx Tx,
vm_transaction_object Transaction,
set_slots Self #{deps: Deps, name: Name, tx: Transaction, version: Version}.

program_execution >> source
| Self Text |
get Self tx Tx,
vm_transaction_source Tx Text _Origin.

program_execution >> listing
| Self Text |
source Self Text.

program_execution >> listing
| Self |
source Self Text,
vm_format "~a~%" [Text].

new class #{ivars: [], name: number, super: value} _.

number >> factorial
| 1 1 |.

number >> factorial
| N Factorial |
N > 1,
Factorial >= 1,
N <= Factorial,
label N,
N1 = N - 1,
factorial N1 Factorial1,
Factorial = Factorial1 * N.

number >> fibonacci
| 1 1 |.

number >> fibonacci
| 2 1 |.

number >> fibonacci
| N X |
N > 2,
X >= 1,
N <= X + 1,
N1 = N - 1,
N2 = N - 2,
fibonacci N1 X1,
fibonacci N2 X2,
X = X1 + X2.

number >> count_to
| N N |.

number >> count_to
| N Target |
N < Target,
N1 = N + 1,
count_to N1 Target.

number >> count_to_via_oapply
| N Target |
method number count_to_oapply_loop Id,
vm_oapply Id [N, Target, Id].

number >> count_to_oapply_loop
| N N _Id |.

number >> count_to_oapply_loop
| N Target Id |
N < Target,
N1 = N + 1,
vm_oapply Id [N1, Target, Id].

new class #{ivars: [], name: list, super: value} _.

class >> witness
| list [] |.

class >> witness
| list [_Head . _Tail] |.

class >> witness
| Self Output |
dif Self list,
dif Self number,
reachable_classes [Self] [] Chain,
not {not {member Chain value}},
construct Self Scaffold,
init Scaffold #{} Output.

list >> hd
| [H . _T] H |.

list >> tl
| [_H . T] T |.

list >> length
| Self N |
ground N,
length_of_size Self N.

list >> length
| Self N |
not {ground N},
length_count Self N.

list >> length_of_size
| [] 0 |.

list >> length_of_size
| [_H . T] N |
N > 0,
N1 = N - 1,
length_of_size T N1.

list >> length_count
| [] 0 |.

list >> length_count
| [_H . T] N |
length_count T N1,
N = N1 + 1.

list >> at
| Xs N X |
at Xs N 0 X.

list >> at
| [H . _T] N N H |.

list >> at
| [H . T] N I V |
I1 = I + 1,
at T N I1 V.

list >> concat
| [] Second Second |.

list >> concat
| [Fh . Ft] Second [Fh . Inner] |
concat Ft Second Inner.

vm_set_method list member list_member.
vm_set_class list_member behaviour.
vm_set_oapply list_member [[X . _T], X] {}.
vm_set_oapply list_member [[_H . T], X] {member T X}.

list >> reverse
| [] [] |.

list >> reverse
| [H . T] Reversed |
reverse T ReversedTl,
concat ReversedTl [H] Reversed.

list >> last
| Xs Last |
reverse Xs Sx,
hd Sx Last.

list >> map
| [] _Func [] |.

list >> map
| [Fh . Ft] Func [Sh . St] |
send Fh Func [Sh],
map Ft Func St.

list >> map
| [Fh . Ft] Func [Sh . St] |
isa Func anonymous_method,
run Func [Fh, Sh],
map Ft Func St.

list >> fold_left
| [] _Func Acc Acc |.

list >> fold_left
| [H . T] Func Acc Result |
send Acc Func [H, NextAcc],
fold_left T Func NextAcc Result.

list >> fold_left
| [H . T] Func Acc Result |
isa Func anonymous_method,
run Func [Acc, H, NextAcc],
fold_left T Func NextAcc Result.

list >> fold_right
| [] _Func Acc Acc |.

list >> fold_right
| [H . T] Func Acc Result |
fold_right T Func Acc NextAcc,
send NextAcc Func [H, Result].

list >> fold_right
| [H . T] Func Acc Result |
isa Func anonymous_method,
fold_right T Func Acc NextAcc,
run Func [NextAcc, H, Result].

list >> flatten
| Lists Result |
fold_left Lists concat [] Result.

list >> same_length
| [] [] |.

list >> same_length
| [_Fh . Ft] [_Sh . St] |
same_length Ft St.

list >> sorted_insert
| [] X [X] |.

list >> sorted_insert
| [H . T] X [X, H . T] |
X <= H.

list >> sorted_insert
| [H . T] X [H . Rest] |
X > H,
sorted_insert T X Rest.

list >> sort
| List Sorted |
fold_left List sorted_insert [] Sorted.

list >> dedupe
| [] [] |.

list >> dedupe
| [X] [X] |.

list >> dedupe
| [X, X . Rest] Result |
dedupe [X . Rest] Result.

list >> dedupe
| [X, Y . Rest] [X . Result] |
dif X Y,
dedupe [Y . Rest] Result.

list >> lambda
| Head Method Body |
new anonymous_method #{args: [], body: Body, head: Head} Method.

list >> min_by
| [H . T] Func Min |
lambda [Acc, X, Least] Step {
  send Acc Func [V],
  send X Func [W],
  {W >= V, Least = Acc} ; {W <= V, Least = X}
},
fold_left T Step H Min.

list >> min
| [] _ |.

list >> min
| [X . Xs] Min |
min Xs X Min.

list >> min
| [] Acc Acc |.

list >> min
| [X . Xs] Acc Min |
X <= Acc,
min Xs X Min.

list >> min
| [X . Xs] Acc Min |
X > Acc,
min Xs Acc Min.

list >> max
| [] _ |.

list >> max
| [X . Xs] Max |
max Xs X Max.

list >> max
| [] Acc Acc |.

list >> max
| [X . Xs] Acc Max |
X <= Acc,
max Xs Acc Max.

list >> max
| [X . Xs] Acc Max |
X > Acc,
max Xs X Max.

list >> max_by
| [H . T] Func Max |
lambda [Acc, X, Greatest] Step {
  send Acc Func [V],
  send X Func [W],
  {W <= V, Greatest = Acc} ; {W >= V, Greatest = X}
},
fold_left T Step H Max.

list >> sum
| [] 0 |.

list >> sum
| [H . T] N |
sum T N1,
N = N1 + H.

list >> label_range
| [] _Lo _Hi |.

list >> label_range
| [H . T] Lo Hi |
H >= Lo,
H <= Hi,
label H,
label_range T Lo Hi.

list >> transpose
| [[] . _Rows] [] |.

list >> transpose
| Rows [Firsts . Rest] |
heads_tails Rows Firsts Tails,
transpose Tails Rest.

list >> heads_tails
| [] [] [] |.

list >> heads_tails
| [[H . T] . Rows] [H . Hs] [T . Ts] |
heads_tails Rows Hs Ts.

object >> inheritance_chain
| Self [Self . Chain] |
findall Class ImmediateClasses {class Self Class},
reachable_classes ImmediateClasses [] Classes,
in_degrees Classes Degrees,
filter_zero_degree ImmediateClasses Degrees Ready,
kahn Ready Degrees Chain.

list >> reachable_classes
| [] Seen Seen |.

list >> reachable_classes
| [C . Cs] Seen Result |
member Seen C,
reachable_classes Cs Seen Result.

list >> reachable_classes
| [C . Cs] Seen Result |
not {member Seen C},
findall S Supers {super C S},
concat Supers Cs Cs2,
concat Seen [C] Seen2,
reachable_classes Cs2 Seen2 Result.

list >> in_degrees
| Classes Degrees |
base_degrees Classes #{} Base,
accumulate_degrees Classes Base Degrees.

list >> base_degrees
| [] Degrees Degrees |.

list >> base_degrees
| [C . Cs] Acc Degrees |
put Acc C 0 Acc2,
base_degrees Cs Acc2 Degrees.

list >> accumulate_degrees
| [] Degrees Degrees |.

list >> accumulate_degrees
| [C . Cs] Acc Degrees |
findall S Supers {super C S},
increment_degrees Supers Acc Acc2,
accumulate_degrees Cs Acc2 Degrees.

list >> increment_degrees
| [] Degrees Degrees |.

list >> increment_degrees
| [S . Ss] Acc Degrees |
get Acc S Old,
New = Old + 1,
vm_map_put Acc S New Acc2,
increment_degrees Ss Acc2 Degrees.

list >> filter_zero_degree
| [] _Degrees [] |.

list >> filter_zero_degree
| [C . Cs] Degrees [C . Ready] |
get Degrees C Degree,
Degree = 0,
filter_zero_degree Cs Degrees Ready.

list >> filter_zero_degree
| [C . Cs] Degrees Ready |
get Degrees C Degree,
not {Degree = 0},
filter_zero_degree Cs Degrees Ready.

list >> kahn
| [] _Degrees [] |.

list >> kahn
| [C . Rest] Degrees [C . Chain] |
findall S Supers {super C S},
decrement_ready Supers Degrees Degrees2 NewlyReady,
concat NewlyReady Rest Queue,
kahn Queue Degrees2 Chain.

list >> decrement_ready
| [] Degrees Degrees [] |.

list >> decrement_ready
| [S . Ss] Degrees DegreesOut [S . Ready] |
get Degrees S Old,
New = Old - 1,
New = 0,
put Degrees S New Degrees2,
decrement_ready Ss Degrees2 DegreesOut Ready.

list >> decrement_ready
| [S . Ss] Degrees DegreesOut Ready |
get Degrees S Old,
New = Old - 1,
not {New = 0},
put Degrees S New Degrees2,
decrement_ready Ss Degrees2 DegreesOut Ready.

behaviour >> run
| Self ProvidedArgs |
vm_oapply Self ProvidedArgs.

@anonymous_method
#{
  super: [behaviour, value],
  ivars: [#{name: args}, #{name: head}, #{name: body}]
}.

anonymous_method >> add_arg
| Self Arg Updated |
get Self args Args,
concat Args [Arg] UpdatedArgs,
put Self args UpdatedArgs Updated.

anonymous_method >> run
| Self ProvidedArgs |
get_slots Self #{args: Args, body: Body, head: Head},
concat Args ProvidedArgs AllArgs,
call Head Body AllArgs.
