defprogram bootstrap #{deps => [], version => 40}.

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
vm_set_oapply clear_method [Self, MethodName] (forall {method Self MethodName Impl} {
    findall Head Heads (clause Impl Head _),
    forall {member Heads Head} {vm_retract_oapply Impl Head}
  }).
vm_set_class block class.
vm_set_super block value.
vm_fresh_id BlockRunMethod.
vm_set_method block run BlockRunMethod.
vm_set_class BlockRunMethod behaviour.
vm_set_oapply BlockRunMethod [Self] (call [Self] Self [Self]).
vm_fresh_id BlockForallMethod.
vm_set_method block forall BlockForallMethod.
vm_set_class BlockForallMethod behaviour.
vm_set_oapply BlockForallMethod [Condition, Action] (not {run Condition, not {run Action}}).

object >> does_not_understand
| Self Method Args |
fail.

object >> between
| _Self Low High Low |
<= Low High.

object >> between
| Self Low High Value |
< Low High,
= Next (+ Low 1),
between Self Next High Value.

object >> reorder_clauses
| Self MethodName Left Right |
method Self MethodName MethodObject,
findall [Head, Body] Left (clause MethodObject Head Body),
forall {member Left [Head, _]} {vm_retract_oapply MethodObject Head},
forall {member Right [Head, Body]} {vm_set_oapply MethodObject Head Body}.

object >> print_object
| Self Text |
atom_string Self Text.

behaviour >> print_object
| Self Text |
vm_method_source Self _Seq Text _Provenance.

object >> listing
| Class Name |
method Class Name Impl,
forall {print_object Impl Text} {
  format "~a~%~%" [Text] Output,
  print Output
}.

object >> get
| Self Key Value |
slot Self Key Value.

object >> ivar_name
| _Self Spec Name |
isa Spec map,
get Spec name Name.

object >> validate_ivar_domain
| _Self Spec Value |
get Spec domain Domain -> in_domain Value Domain ; pass.

object >> validate_ivar_type
| _Self Spec Value |
get Spec type Type -> isa Value Type ; pass.

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
not (class Self object),
vm_cached_find_ivar_spec Self Key Spec,
not (= Spec no_spec),
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
findall Key Keys (get Requested Key _),
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
findall V RawValues (vm_slot_at Self Key V _T),
dedupe RawValues Values.

vm_set_class map class.

map >> get
| Self Key Value |
map_get Self Key Value.

map >> get
| Self Key _Default Value |
map_get Self Key Value.

map >> get
| Self Key Default Default |
not (map_get Self Key _).

map >> put
| Self Key Value Updated |
vm_map_put Self Key Value Updated.

map >> put_new
| Self Key _Default Self |
get Self Key _Value.

map >> put_new
| Self Key Default Updated |
not (get Self Key _Value),
put Self Key Default Updated.

object >> get_optional
| Self Key Value |
not (get Self Key _) -> pass ; get Self Key Value.

object >> retract_existing_facts
| Self |
retract_declaration Self,
findall [N, Id] ExistingMethods (method Self N Id),
forall {member ExistingMethods [N, Id]} {vm_retract_method Self N Id}.

object >> retract_declaration
| Self |
findall C ExistingClasses (class Self C),
forall {member ExistingClasses C} {vm_retract_class Self C},
findall S ExistingSupers (super Self S),
forall {member ExistingSupers S} {vm_retract_super Self S},
findall K ExistingAosKeys (slot Self K _),
vm_cached_ivar_specs Self IvarSpecs,
ivar_names IvarSpecs DeclaredNames,
findall K ExistingSoaKeys {member DeclaredNames K, slot Self K _ soa},
concat ExistingAosKeys ExistingSoaKeys ExistingSlotKeys,
forall {member ExistingSlotKeys K} {vm_retract_slot Self K}.

object >> claim_name
| Self Name |
class Name _ -> retract_declaration Name ; pass.

class >> construct
| Self #{class => Self} |.

vm_set_method class allocate allocate_class.
vm_set_class allocate_class behaviour.
vm_set_oapply allocate_class [Self, Args, Name] {
  get Args name Name,
  get Args super object Super,
  get Args ivars [] Ivars,
  ivar_names Ivars _,
  class Self Meta,
  class Name _ -> {
    findall S OldSupers (super Name S),
    slot Name ivars OldIvars,
    = Existed true
  } ; {= OldSupers [], = OldIvars [], = Existed false},
  claim_name Self Name,
  vm_set_class Name Meta,
  set_supers Name Super,
  set_slot Name ivars Ivars,
  = Existed true -> {
    findall S NewSupers (super Name S),
    class_redefined Name #{ivars => OldIvars, supers => OldSupers} #{ivars => Ivars, supers => NewSupers}
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
  not (member OldNames Name)
},
findall Name RemovedNames {member OldNames Name, not (member NewNames Name)},
findall O Instances {isa O Self, label O},
forall {member Instances O} {reconcile_redefined_instance O AddedSpecs RemovedNames}.

class >> delete_class
| Self |
findall S OldSupers (super Self S),
slot Self ivars OldIvars,
class_redefined Self #{ivars => OldIvars, supers => OldSupers} #{ivars => [], supers => []},
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
not (get Spec default _Default).

object >> set_supers
| Name Super |
class Super list,
set_super_list Name Super.

object >> set_supers
| Name Super |
not (class Super list),
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
slot C ivars OwnSpecs,
collect_ivar_specs Rest RestSpecs,
concat OwnSpecs RestSpecs Specs.

list >> collect_ivar_specs
| [C . Rest] RestSpecs |
not (slot C ivars _),
collect_ivar_specs Rest RestSpecs.

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
cut,
vm_map_put Partial Name Value Output.

object >> include_durable_slot
| Partial Name Value Output |
not (ground Value),
class Value anonymous_method,
get Value args Args,
ground Args,
cut,
vm_map_put Partial Name Value Output.

object >> include_durable_slot
| Partial _Name Value Partial |
not (ground Value),
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

new class #{ivars => [], name => category, super => object} _.

object >> copy_methods
| _Self [] |.

object >> copy_methods
| Self [[Name, Id] . Rest] |
vm_set_method Self Name Id,
copy_methods Self Rest.

object >> import
| Self Category |
findall [Name, Id] Pairs (method Category Name Id),
copy_methods Self Pairs.

new class #{ivars => [], name => value, super => object} _.

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
map_get Self class Class,
ground Class -> vm_cached_ivar_specs Self IvarSpecs ; {
  reachable_classes [Class] [] Chain,
  collect_ivar_specs Chain IvarSpecs
},
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
{not (get Args Name _), get Spec default Default} -> = Value Default ; pass,
get_optional Args Name Value.

object >> build_from_ivar_specs
| Self Class Args [] #{class => Class} |.

object >> build_from_ivar_specs
| Self Class Args [Spec . Rest] Output |
build_from_ivar_specs Self Class Args Rest Partial,
apply_ivar_spec Self Args Spec Name Value,
vm_map_put Partial Name Value Output.

vm_set_super map object.
vm_set_class defclass behaviour.
vm_set_oapply defclass [Name, Metaclass, Super, Ivars, Categories] {
  new Metaclass #{ivars => Ivars, name => Name, super => Super} _,
  forall {member Categories Category} {import Name Category}
}.
vm_set_class extend_class behaviour.
vm_set_oapply extend_class [Name, Supers] (forall {member Supers S} {super Name S -> pass ; vm_set_super Name S}).

object >> examine
| Self #{
  class_supers => ClassSupers,
  classes => Classes,
  clauses => Clauses,
  direct_slots => DirectSlots,
  id => Self,
  instances => Instances,
  methods => Methods,
  providers => Providers,
  subs => Subs,
  supers => Supers
} |
findall C Classes (class Self C),
findall [C, S] ClassSupers {class Self C, super C S},
findall C Instances {class C Self, label C},
findall S Supers (super Self S),
findall Sub Subs (super Sub Self),
findall [N, Id] Methods (method Self N Id),
findall [Provider, N] Providers {method Provider N Self, label Provider},
findall [Head, Body] Clauses (clause Self Head Body),
findall [SlotName, SlotValue] DirectSlots (slot Self SlotName SlotValue).

new class #{
  ivars => [#{name => name}, #{name => version}, #{name => deps}, #{name => tx}],
  name => program_execution,
  super => object
} _.
new class #{
  ivars => [
    #{name => tx}, #{name => branch}, #{name => status}, #{name => reason},
    #{name => run}, #{name => caused_by}, #{name => children}, #{name => futures},
    #{name => effects}, #{name => waits}, #{name => completed_objects},
    #{name => completion_of}
  ],
  name => transaction,
  super => object
} _.
@completion #{super => object}.

completion >> outcome
| Self Outcome |
get Self status completed,
get Self outcome Outcome.

new class #{
  ivars => [#{name => effect}, #{name => head}, #{name => goals}, #{name => status},
    #{name => wait_transaction}, #{name => outcome},
    #{name => requested_by}, #{name => completed_by}],
  name => future_transaction,
  super => completion
} _.

future_transaction >> init
| Self Args Self |
get_slots Args #{effect => Effect, goals => Goals, head => Head, status => waiting},
get Effect completion_transaction WaitTransaction,
vm_transaction_object RequestedBy,
set_slots Self #{effect => Effect, goals => Goals, head => Head,
  requested_by => RequestedBy, status => waiting,
  wait_transaction => WaitTransaction}.

future_transaction >> init
| Self Args Self |
get_slots Args #{effect => Effect, goals => Goals, head => Head, status => ready},
vm_transaction_object RequestedBy,
set_slots Self #{effect => Effect, goals => Goals, head => Head,
  requested_by => RequestedBy, status => ready,
  wait_transaction => none}.

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
get_slots Self #{goals => Goals, head => Head},
set_slot Self status running,
call Head Goals Arguments.

future_transaction >> complete
| Self Outcome |
get Self status Status,
dif Status completed,
vm_transaction_object Transaction,
set_slots Self #{status => completed, outcome => Outcome, completed_by => Transaction}.

future_transaction >> failed
| Self Outcome |
get Self status Status,
in_domain Status [ready, waiting],
complete Self Outcome.

new class #{
  ivars => [
    #{name => provider},
    #{name => operation},
    #{name => arguments},
    #{name => completion_transaction},
    #{name => status},
    #{name => outcome},
    #{name => requested_by},
    #{name => completed_by}
  ],
  name => effect,
  super => completion
} _.

effect >> init
| Self Args Self |
get Args provider Provider,
get Args operation Operation,
get Args arguments Arguments,
vm_transaction_object RequestedBy,
new transaction #{status => pending, completion_of => Self} CompletionTransaction,
set_slots Self #{
  arguments => Arguments,
  completed_by => none,
  completion_transaction => CompletionTransaction,
  operation => Operation,
  outcome => none,
  provider => Provider,
  requested_by => RequestedBy,
  status => pending
},
vm_emit_effect Self Provider Operation Arguments.

effect >> complete
| Self Outcome |
get Self status pending,
get Self completion_transaction CompletionTransaction,
vm_transaction_object CompletedBy,
= CompletedBy CompletionTransaction,
set_slots Self #{completed_by => CompletedBy, outcome => Outcome, status => completed}.

effect >> set_slot
| Self status completed |
get Self completion_transaction CompletionTransaction,
vm_transaction_object CompletionTransaction,
validate_slot Self status completed,
vm_set_slot Self status completed.

effect >> set_slot
| Self completion_transaction CompletionTransaction |
not (slot Self completion_transaction _),
validate_slot Self completion_transaction CompletionTransaction,
vm_set_slot Self completion_transaction CompletionTransaction.

effect >> set_slot
| Self Key Value |
dif [Key, Value] [status, completed],
dif Key completion_transaction,
validate_slot Self Key Value,
vm_set_slot Self Key Value.

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
set_slots Self #{deps => Deps, name => Name, tx => Transaction, version => Version}.

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
format "~a~%" [Text] Output,
print Output.

new class #{ivars => [], name => number, super => value} _.

@branch #{super => object, ivars => [#{name => command_log, type => command_log}]}.

@command_log #{super => object, ivars => [#{name => branch, type => branch}]}.

@command #{
  super => value,
  ivars => [
    #{name => branch, type => branch},
    #{name => position, type => number},
    #{name => transaction},
    #{name => action},
    #{name => arguments, type => list}
  ]
}.

branch >> command_log
| Self Log |
vm_current_branch Self,
get Self command_log Log,
get Log branch Self.

branch >> command_log
| Self Log |
vm_current_branch Self,
not {get Self command_log Existing, get Existing branch Self},
new command_log #{branch => Self} Log,
set_slot Self command_log Log.

command_log >> at
| Self Position Command |
get Self branch Branch,
vm_current_branch Branch,
vm_command TxId Position Operation,
get Operation action Action,
get Operation arguments Arguments,
transaction_for Self TxId Transaction,
new command #{
  branch => Branch,
  position => Position,
  transaction => Transaction,
  action => Action,
  arguments => Arguments
} Command.

command_log >> transaction_for
| _Self TxId Transaction |
vm_current_tx TxId,
vm_transaction_object Transaction.

command_log >> transaction_for
| _Self TxId Transaction |
isa Transaction transaction,
label Transaction,
get Transaction tx TxId.

command_log >> in_transaction
| Self Transaction Command |
get Self branch Branch,
vm_current_branch Branch,
transaction_for Self TxId Transaction,
vm_command TxId Position Operation,
get Operation action Action,
get Operation arguments Arguments,
new command #{
  branch => Branch,
  position => Position,
  transaction => Transaction,
  action => Action,
  arguments => Arguments
} Command.

command_log >> since
| Self Start Command |
ground Start,
get Self branch Branch,
vm_current_branch Branch,
vm_branch_meta Branch system_time End,
= Last (- End 1),
between Self Start Last Position,
at Self Position Command.

command_log >> latest
| Self Command |
get Self branch Branch,
vm_current_branch Branch,
findall P [First . Rest] {vm_command _ P _},
max [First . Rest] Position,
at Self Position Command.

command >> transaction
| Self Transaction |
get Self transaction Transaction.

branch >> parent
| Self Parent |
vm_branch Parent Self.

branch >> child
| Self Child |
vm_branch Self Child.

branch >> fork_point
| Self Point |
vm_branch_meta Self fork_point Point.

branch >> system_time
| Self Time |
vm_branch_meta Self system_time Time.

branch >> current
| Self |
vm_current_branch Self.

branch >> checked_out
| Self |
vm_branch_meta main head Self.

branch >> fork
| Self At Effect |
ground Self,
new effect #{arguments => [Self, At], operation => fork, provider => branch} Effect.

branch >> reset
| Self Effect |
ground Self,
new effect #{arguments => [Self], operation => reset, provider => branch} Effect.

branch >> reset_to
| Self At Effect |
ground Self,
new effect #{arguments => [Self, At], operation => reset_to, provider => branch} Effect.

branch >> discard
| Self Effect |
ground Self,
new effect #{arguments => [Self], operation => discard, provider => branch} Effect.

branch >> checkout
| Self Effect |
ground Self,
new effect #{arguments => [Self], operation => checkout, provider => branch} Effect.

new class #{ivars => [], name => string, super => value} _.

string >> concat
| Self Other Whole |
vm_text_concat Self Other Whole.

string >> length
| Self N |
vm_text_length Self N.

string >> uncons
| Self Char Rest |
vm_text_code Self Code Rest,
vm_text_code Char Code "".

string >> empty
| _Self "" |.

list >> empty
| _Self [] |.

string >> contains
| Self Part |
vm_text_concat _Prefix Suffix Self,
vm_text_concat Part _Rest Suffix.

string >> split
| Self Separator [Self] |
= Separator [_ . _Rest],
not {contains Self Separator}.

string >> split
| Self Separator [Part . Parts] |
= Separator [_ . _Rest],
vm_text_concat Part Separated Self,
vm_text_concat Separator Rest Separated,
vm_text_concat Part Separator ThroughSeparator,
vm_text_concat BeforeLast Last ThroughSeparator,
= Last [_ . ""],
not {contains BeforeLast Separator},
split Rest Separator Parts.

list >> join_text
| Self Text |
vm_text_join Self Text.

number >> factorial
| 1 1 |.

number >> factorial
| N Factorial |
> N 1,
>= Factorial 1,
<= N Factorial,
label N,
= N1 (- N 1),
factorial N1 Factorial1,
= Factorial (* Factorial1 N).

number >> fibonacci
| 1 1 |.

number >> fibonacci
| 2 1 |.

number >> fibonacci
| N X |
> N 2,
>= X 1,
<= N (+ X 1),
= N1 (- N 1),
= N2 (- N 2),
fibonacci N1 X1,
fibonacci N2 X2,
= X (+ X1 X2).

number >> count_to
| N N |.

number >> count_to
| N Target |
< N Target,
= N1 (+ N 1),
count_to N1 Target.

number >> count_to_via_oapply
| N Target |
method number count_to_oapply_loop Id,
vm_oapply Id [N, Target, Id].

number >> count_to_oapply_loop
| N N _Id |.

number >> count_to_oapply_loop
| N Target Id |
< N Target,
= N1 (+ N 1),
vm_oapply Id [N1, Target, Id].

new class #{ivars => [], name => list, super => value} _.

new class #{ivars => [], name => compound, super => value} _.

class >> value_ancestor
| value _Seen |.

class >> value_ancestor
| Self Seen |
not (member Seen Self),
super Self Parent,
value_ancestor Parent [Self . Seen].

class >> witness
| list [] |.

class >> witness
| list [_Head . _Tail] |.

class >> witness
| Self Output |
dif Self list,
dif Self number,
ground Self -> not (not (value_ancestor Self [])) ; {
  reachable_classes [Self] [] Chain,
  not (not (member Chain value))
},
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
not (ground N),
length_count Self N.

list >> length_of_size
| [] 0 |.

list >> length_of_size
| [_H . T] N |
> N 0,
= N1 (- N 1),
length_of_size T N1.

list >> length_count
| [] 0 |.

list >> length_count
| [_H . T] N |
length_count T N1,
= N (+ N1 1).

list >> at
| Xs N X |
at Xs N 0 X.

list >> at
| [H . _T] N N H |.

list >> at
| [H . T] N I V |
= I1 (+ I 1),
at T N I1 V.

list >> concat
| [] Second Second |.

list >> concat
| [Fh . Ft] Second [Fh . Inner] |
concat Ft Second Inner.

list >> contains
| Self Sublist |
concat _Prefix Suffix Self,
concat Sublist _Rest Suffix.

list >> split
| Self [Separator . Separators] [Self] |
not (contains Self [Separator . Separators]).

list >> split
| Self [Separator . Separators] [Part . Parts] |
concat Part Separated Self,
concat [Separator . Separators] Rest Separated,
concat Part [Separator . Separators] ThroughSeparator,
concat BeforeLast [_Last] ThroughSeparator,
not (contains BeforeLast [Separator . Separators]),
split Rest [Separator . Separators] Parts.

vm_set_method list member list_member.
vm_set_class list_member behaviour.
vm_set_oapply list_member [[X . _T], X] {}.
vm_set_oapply list_member [[_H . T], X] (member T X).

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
atom Func,
fold_right T Func Acc NextAcc,
send NextAcc Func [H, Result].

list >> fold_right
| [H . T] Func Acc Result |
isa Func anonymous_method,
fold_right T Func Acc NextAcc,
run Func [NextAcc, H, Result].

list >> flatten
| [] [] |.

list >> flatten
| [List . Lists] Result |
concat List Rest Result,
flatten Lists Rest.

list >> join
| Strings Text |
strings_codes Strings Lists,
flatten Lists Codes,
string_codes Text Codes.

list >> same_length
| [] [] |.

list >> same_length
| [_Fh . Ft] [_Sh . St] |
same_length Ft St.

list >> sorted_insert
| [] X [X] |.

list >> sorted_insert
| [H . T] X [X, H . T] |
<= X H.

list >> sorted_insert
| [H . T] X [H . Rest] |
> X H,
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
new anonymous_method #{args => [], body => Body, head => Head} Method.

list >> min_by
| [H . T] Func Min |
lambda [Acc, X, Least] Step {
  send Acc Func [V],
  send X Func [W],
  {>= W V, = Least Acc} ; {<= W V, = Least X}
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
<= X Acc,
min Xs X Min.

list >> min
| [X . Xs] Acc Min |
> X Acc,
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
<= X Acc,
max Xs Acc Max.

list >> max
| [X . Xs] Acc Max |
> X Acc,
max Xs X Max.

list >> max_by
| [H . T] Func Max |
lambda [Acc, X, Greatest] Step {
  send Acc Func [V],
  send X Func [W],
  {<= W V, = Greatest Acc} ; {>= W V, = Greatest X}
},
fold_left T Step H Max.

list >> sum
| [] 0 |.

list >> sum
| [H . T] N |
sum T N1,
= N (+ N1 H).

list >> label_range
| [] _Lo _Hi |.

list >> label_range
| [H . T] Lo Hi |
>= H Lo,
<= H Hi,
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
findall Class ImmediateClasses (class Self Class),
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
not (member Seen C),
findall S Supers (super C S),
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
findall S Supers (super C S),
increment_degrees Supers Acc Acc2,
accumulate_degrees Cs Acc2 Degrees.

list >> increment_degrees
| [] Degrees Degrees |.

list >> increment_degrees
| [S . Ss] Acc Degrees |
get Acc S Old,
= New (+ Old 1),
vm_map_put Acc S New Acc2,
increment_degrees Ss Acc2 Degrees.

list >> filter_zero_degree
| [] _Degrees [] |.

list >> filter_zero_degree
| [C . Cs] Degrees [C . Ready] |
get Degrees C Degree,
= Degree 0,
filter_zero_degree Cs Degrees Ready.

list >> filter_zero_degree
| [C . Cs] Degrees Ready |
get Degrees C Degree,
not (= Degree 0),
filter_zero_degree Cs Degrees Ready.

list >> kahn
| [] _Degrees [] |.

list >> kahn
| [C . Rest] Degrees [C . Chain] |
findall S Supers (super C S),
decrement_ready Supers Degrees Degrees2 NewlyReady,
concat NewlyReady Rest Queue,
kahn Queue Degrees2 Chain.

list >> decrement_ready
| [] Degrees Degrees [] |.

list >> decrement_ready
| [S . Ss] Degrees DegreesOut [S . Ready] |
get Degrees S Old,
= New (- Old 1),
= New 0,
put Degrees S New Degrees2,
decrement_ready Ss Degrees2 DegreesOut Ready.

list >> decrement_ready
| [S . Ss] Degrees DegreesOut Ready |
get Degrees S Old,
= New (- Old 1),
not (= New 0),
put Degrees S New Degrees2,
decrement_ready Ss Degrees2 DegreesOut Ready.

behaviour >> run
| Self ProvidedArgs |
vm_oapply Self ProvidedArgs.

block >> run
| Self |
call [Self] Self [Self].

block >> forall
| Condition Action |
not {run Condition, not {run Action}}.

@anonymous_method
#{
  super => [behaviour, value],
  ivars => [#{name => args}, #{name => head}, #{name => body}]
}.

anonymous_method >> add_arg
| Self Arg Updated |
get Self args Args,
concat Args [Arg] UpdatedArgs,
put Self args UpdatedArgs Updated.

anonymous_method >> run
| Self ProvidedArgs |
get_slots Self #{args => Args, body => Body, head => Head},
concat Args ProvidedArgs AllArgs,
call Head Body AllArgs.

@grammar #{super => class}.

@syntax #{super => value, metaclass => grammar}.

syntax >> init
| Self _Args Self |.

syntax >> word
| Self Input Rest Word |
atom_string Word Text,
text Self Input Rest word_char word_char Text.

syntax >> word_char
| _Self [Char . Rest] Rest Char |
in_domain Char [
  "a",
  "b",
  "c",
  "d",
  "e",
  "f",
  "g",
  "h",
  "i",
  "j",
  "k",
  "l",
  "m",
  "n",
  "o",
  "p",
  "q",
  "r",
  "s",
  "t",
  "u",
  "v",
  "w",
  "x",
  "y",
  "z"
].

syntax >> variable_word
| Self Input Rest Name |
text Self Input Rest variable_start_char variable_char Name.

syntax >> variable_start_char
| _Self [Char . Rest] Rest Char |
in_domain Char [
  "A",
  "B",
  "C",
  "D",
  "E",
  "F",
  "G",
  "H",
  "I",
  "J",
  "K",
  "L",
  "M",
  "N",
  "O",
  "P",
  "Q",
  "R",
  "S",
  "T",
  "U",
  "V",
  "W",
  "X",
  "Y",
  "Z",
  "_"
].

syntax >> variable_char
| Self Input Rest Char |
word_char Self Input Rest Char.

syntax >> variable_char
| Self Input Rest Char |
variable_start_char Self Input Rest Char.

syntax >> variable_char
| _Self [Char . Rest] Rest Char |
in_domain Char ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"].

syntax >> text
| Self Input Rest First More [Char . Text] |
send Self First [Input, After, Char],
text_rest Self After Rest More Text.

syntax >> text_rest
| Self Input Rest Pattern [Char . Text] |
send Self Pattern [Input, After, Char],
dif Input After,
text_rest Self After Rest Pattern Text.

syntax >> text_rest
| _Self Rest Rest _Pattern "" |.

syntax >> delimited_text
| Self Input Rest Terminator Pattern Text |
text_prefix Self Input After Pattern Text,
literal Self Terminator After Rest.

syntax >> text_prefix
| _Self Rest Rest _Pattern "" |.

syntax >> text_prefix
| Self Input Rest Pattern [Char . Text] |
send Self Pattern [Input, After, Char],
text_prefix Self After Rest Pattern Text.

syntax >> consume
| Self Input Rest Pattern |
not {var Input},
send Self Pattern [Input, After, _],
dif Input After,
consume Self After Rest Pattern.

syntax >> consume
| _Self Rest Rest _Pattern |.

syntax >> match_pattern
| Self Pattern Input Rest |
atom Pattern,
send Self Pattern [Input, Rest].

syntax >> match_pattern
| _Self Pattern Input Rest |
class Pattern list,
concat Pattern Rest Input.

syntax >> match_pattern
| Self Pattern Input Rest |
class Pattern string,
literal Self Pattern Input Rest.

syntax >> match_pattern
| Self Pattern Input Rest |
functor Pattern Rule Args,
atom Rule,
concat [Input, Rest] Args CallArgs,
send Self Rule CallArgs.

syntax >> literal
| _Self "" Rest Rest |.

syntax >> literal
| Self [Char . Chars] [Char . Input] Rest |
literal Self Chars Input Rest.

syntax >> char
| _Self [Char . Rest] Rest Char |.

syntax >> token
| _Self [Token . Rest] Rest Token |.

syntax >> known_text
| _Self Input Input |
not {var Input}.

syntax >> unknown_text
| _Self Input Input |
var Input.

syntax >> unless
| Self Rest Rest Pattern |
not {match_pattern Self Pattern Rest _}.

syntax >> within
| Self Rest Rest Input Patterns |
sequence Self Patterns Input End,
empty Input End.

syntax >> where
| _Self Rest Rest Args Goals |
call Args Goals Args.

syntax >> zero_or_more
| Self Input Rest Pattern [Value . Values] |
send Self Pattern [Input, After, Value],
dif Input After,
zero_or_more Self After Rest Pattern Values.

syntax >> zero_or_more
| _Self Rest Rest _Pattern [] |.

syntax >> sequence
| _Self [] Rest Rest |.

syntax >> sequence
| Self [Pattern . Patterns] Input Rest |
match_pattern Self Pattern Input After,
sequence Self Patterns After Rest.

grammar >> phrase
| Self Pattern Input |
new Self Receiver,
match_pattern Receiver Pattern Input Rest,
empty Input Rest.

grammar >> phrase
| Self Pattern Input Rest |
new Self Receiver,
match_pattern Receiver Pattern Input Rest.

grammar >> parse
| Self Pattern Text |
phrase Self Pattern Text "".

grammar >> translate
| Self Target Pattern Text Translated |
parse Self Pattern Text,
parse Target Pattern Translated.

grammar >> defrule
| Self RuleName Patterns |
atom RuleName,
rule_goals Self Grammar Patterns [] Input Rest Body,
defmethod Self RuleName [Grammar, Input, Rest] Body.

grammar >> defrule
| Self Head Patterns |
functor Head RuleName Args,
atom RuleName,
rule_goals Self Grammar Patterns Args Input Rest Body,
concat [Grammar, Input, Rest] Args MethodHead,
defmethod Self RuleName MethodHead Body.

grammar >> rule_goals
| _Self _Grammar [] _Args Rest Rest [] |.

grammar >> rule_goals
| Self Grammar [Pattern . Patterns] Args Input Rest [Goal . Goals] |
pattern_goal Self Grammar Pattern Args Input After Goal,
rule_goals Self Grammar Patterns Args After Rest Goals.

grammar >> pattern_goal
| Self Grammar Pattern Args Input Rest Goal |
pattern_kind Self Pattern Kind,
kind_goal Self Kind Grammar Pattern Args Input Rest Goal.

grammar >> pattern_kind
| _Self Pattern Kind |
var Pattern -> = Kind open ;
== Pattern known_text -> = Kind known ;
== Pattern unknown_text -> = Kind unknown ;
atom Pattern -> = Kind name ;
class Pattern string -> = Kind text ;
class Pattern list -> = Kind tokens ;
functor Pattern where [_, _] -> = Kind where ;
functor Pattern char [_] -> = Kind char ;
= Kind call.

grammar >> kind_goal
| _Self open Grammar Pattern _Args Input Rest Goal |
functor Goal match_pattern [Grammar, Pattern, Input, Rest].

grammar >> kind_goal
| _Self text _Grammar Text _Args Input Rest Goal |
literal #{class => syntax} Text Expected Rest,
functor Goal = [Input, Expected].

grammar >> kind_goal
| _Self tokens _Grammar Tokens _Args Input Rest Goal |
concat Tokens Rest Expected,
functor Goal = [Input, Expected].

grammar >> kind_goal
| _Self known _Grammar _Pattern _Args Input Rest Goal |
= Input Rest,
functor Test var [Input],
functor Goal not [[Test]].

grammar >> kind_goal
| _Self unknown _Grammar _Pattern _Args Input Rest Goal |
= Input Rest,
functor Goal var [Input].

grammar >> kind_goal
| _Self where _Grammar Pattern _Args Input Rest Goal |
= Input Rest,
functor Pattern where [Vars, Block],
block_goals Block Goals,
functor Goal call [Vars, Goals, Vars].

grammar >> kind_goal
| _Self char _Grammar Pattern _Args Input Rest Goal |
functor Pattern char [Char],
functor Goal = [Input, [Char . Rest]].

grammar >> kind_goal
| Self name Grammar Name Args Input Rest Goal |
call_goal Self Grammar Name Args [] Input Rest Goal.

grammar >> kind_goal
| Self call Grammar Pattern _Args Input Rest Goal |
functor Pattern Name Arguments,
call_goal Self Grammar Name Arguments Arguments Input Rest Goal.

grammar >> call_goal
| _Self Grammar next NextArgs _Arguments Input Rest Goal |
concat [Grammar, Input, Rest] NextArgs CallArgs,
functor Goal call_next_method CallArgs.

grammar >> call_goal
| _Self Grammar Name _NextArgs Arguments Input Rest Goal |
dif Name next,
functor Goal send [Grammar, Name, [Input, Rest . Arguments]].

@lisp_syntax #{super => syntax, metaclass => grammar}.

defrule lisp_syntax blank [" "].
defrule lisp_syntax blank ["\n"].
defrule lisp_syntax blank ["\t"].
defrule lisp_syntax blank ["\r"].
defrule lisp_syntax blanks [known_text, blank, blanks].
defrule lisp_syntax blanks [].
defrule lisp_syntax gap [unknown_text, " "].
defrule lisp_syntax gap [known_text, blank, blanks].
defrule lisp_syntax pad [unknown_text, " "].
defrule lisp_syntax pad [known_text, gap].
defrule lisp_syntax pad [known_text].
defrule lisp_syntax (expr Symbol) [symbol Symbol].
defrule lisp_syntax (expr Term) ["(", blanks, form Term, blanks, ")"].

defrule lisp_syntax (form Term)
[where [Term, Head, Args] {functor Term Head Args}, symbol Head, spaced_exprs Args].

defrule lisp_syntax (spaced_exprs []) [].
defrule lisp_syntax (spaced_exprs [Expr . Exprs]) [gap, expr Expr, spaced_exprs Exprs].

defrule lisp_syntax (symbol Symbol)
[where [Symbol] {var Symbol}, text symbol_char symbol_char Text,
  where [Symbol, Text] {atom_string Symbol Text}].
defrule lisp_syntax (symbol Symbol)
[where [Symbol, Text] {atom Symbol, atom_string Symbol Text},
  text symbol_char symbol_char Text].
defrule lisp_syntax (symbol_char Char)
[char Char,
  where [Char] {dif Char " ", dif Char "\t", dif Char "\n", dif Char "\r", dif Char "(", dif Char ")"}].

@tag_syntax #{super => lisp_syntax, metaclass => grammar}.

defrule tag_syntax (expr []) ["(", blanks, ")"].
defrule tag_syntax (expr Term) [next].

defrule tag_syntax (form Items) ["list", spaced_exprs Items].
defrule tag_syntax (form [First . Rest]) ["list*", gap, expr First, spaced_tail Rest].
defrule tag_syntax (form Map)
[known_text, "map", tagged_entries Entries, where [Map, Entries] {map_pairs Map Entries}].
defrule tag_syntax (form Map)
[unknown_text, where [Map, Entries] {map_pairs Map Entries}, "map", tagged_entries Entries].
defrule tag_syntax (form Term)
[where [Term, Head] {functor Term Head _, dif Head list, dif Head 'list*', dif Head map},
  next].

defrule tag_syntax (spaced_tail Tail) [gap, expr Tail].
defrule tag_syntax (spaced_tail [Expr . Rest]) [gap, expr Expr, spaced_tail Rest].

defrule tag_syntax (tagged_entries []) [].
defrule tag_syntax (tagged_entries [[Key, Value] . More])
[gap, "(", blanks, expr Key, gap, expr Value, blanks, ")", tagged_entries More].

@list_syntax #{super => lisp_syntax, metaclass => grammar}.

defrule list_syntax (expr List)
["[", where [List] {class List list, = List []}, blanks, "]"].
defrule list_syntax (expr List)
["[", where [List, First, More] {class List list, = List [First . More]},
  blanks, expr First, list_rest More, blanks, "]"].
defrule list_syntax (expr Term) [next].

defrule list_syntax (list_rest []) [].
defrule list_syntax (list_rest [Expr . More]) [blanks, ",", pad, expr Expr, list_rest More].
defrule list_syntax (list_rest Tail) [pad, ".", pad, expr Tail].

defrule list_syntax (symbol_char Char)
[next, where [Char] {dif Char ",", dif Char ".", dif Char "[", dif Char "]"}].

@block_syntax #{super => lisp_syntax, metaclass => grammar}.

defrule block_syntax (expr Block)
[known_text, "{", blanks, block_goals Goals, blanks, "}",
  where [Block, Goals] {block_goals Block Goals}].
defrule block_syntax (expr Block)
[unknown_text, where [Block, Goals] {block_goals Block Goals},
  "{", blanks, block_goals Goals, blanks, "}"].
defrule block_syntax (expr Term) [next].

defrule block_syntax (block_goals []) [].
defrule block_syntax (block_goals [First . More]) [goal First, goal_rest More].

defrule block_syntax (goal Goal)
[where [Goal, Head, Args] {functor Goal Head Args},
  symbol Head,
  spaced_exprs Args,
  where [Goal] {not {functor Goal var [Name], isa Name string}}].
defrule block_syntax (goal_rest []) [].
defrule block_syntax (goal_rest [Goal . More]) [blanks, ",", pad, goal Goal, goal_rest More].

defrule block_syntax (symbol_char Char)
[next, where [Char] {dif Char ",", dif Char "{", dif Char "}"}].

@map_syntax #{super => block_syntax, metaclass => grammar}.

defrule map_syntax (expr Map)
[known_text,
  "\#{",
  blanks,
  map_entries Entries,
  blanks,
  "}",
  where [Map, Entries] {map_pairs Map Entries}].
defrule map_syntax (expr Map)
[unknown_text,
  where [Map, Entries] {map_pairs Map Entries},
  "\#{",
  blanks,
  map_entries Entries,
  blanks,
  "}"].
defrule map_syntax (expr Term) [next].

defrule map_syntax (map_entries []) [].
defrule map_syntax (map_entries [Entry . More]) [entry Entry, entry_rest More].
defrule map_syntax (entry_rest []) [].
defrule map_syntax (entry_rest [Entry . More]) [blanks, ",", pad, entry Entry, entry_rest More].
defrule map_syntax (entry [Key, Value]) [expr Key, pad, "=>", pad, expr Value].

@number_syntax #{super => lisp_syntax, metaclass => grammar}.

defrule number_syntax (symbol Number)
[where [Number] {isa Number number}, integer Number].
defrule number_syntax (symbol Atom) [next Atom, unless (integer_name Atom)].

defrule number_syntax (integer_name Name)
[where [Name, Text] {atom Name, atom_string Name Text}, within Text [integer _]].

defrule number_syntax (integer Number) [natural Number].
defrule number_syntax (integer Number)
["-",
  where [Number, Magnitude] {= Number (- 0 Magnitude), >= Magnitude 1},
  natural Magnitude].
defrule number_syntax (natural 0) ["0"].
defrule number_syntax (natural Number)
[where [Number] {var Number}, digit Digit,
  where [Digit] {>= Digit 1}, digits Digit Number].
defrule number_syntax (natural Number)
[where [Number] {not {var Number}, >= Number 1, <= Number 9}, digit Number].
defrule number_syntax (natural Number)
[where [Number, Prefix, Digit] {
  not {var Number}, >= Number 10,
  = Digit (rem Number 10), = Prefix (/ Number 10)
}, natural Prefix, digit Digit].
defrule number_syntax (digits Number Number) [].
defrule number_syntax (digits Acc Number)
[digit Digit,
  where [Acc, Digit, Next, Number] {= Next (+ (* Acc 10) Digit), <= Next Number},
  digits Next Number].
defrule number_syntax (digit 0) ["0"].
defrule number_syntax (digit 1) ["1"].
defrule number_syntax (digit 2) ["2"].
defrule number_syntax (digit 3) ["3"].
defrule number_syntax (digit 4) ["4"].
defrule number_syntax (digit 5) ["5"].
defrule number_syntax (digit 6) ["6"].
defrule number_syntax (digit 7) ["7"].
defrule number_syntax (digit 8) ["8"].
defrule number_syntax (digit 9) ["9"].

@variable_syntax #{super => lisp_syntax, metaclass => grammar}.

defrule variable_syntax (symbol (var Name))
[text variable_start_char symbol_char Name].
defrule variable_syntax (symbol Term)
[known_text, unless variable_start, next Term].
defrule variable_syntax (symbol Term)
[unknown_text, next Term, unless (variable_name Term)].

defrule variable_syntax (variable_name Name)
[where [Name, Text] {atom Name, atom_string Name Text},
  within Text [variable_start, consume char]].

defrule variable_syntax variable_start [variable_start_char _].

@string_syntax #{super => lisp_syntax, metaclass => grammar}.

defrule string_syntax (expr String) ["\"", quoted_string String].
defrule string_syntax (expr Term) [next].

defrule string_syntax (quoted_string String)
[known_text, delimited_text "\"" character String].
defrule string_syntax (quoted_string String)
[unknown_text, characters String, "\""].

string_syntax >> characters
| Self Input Rest Text |
text_prefix Self Input Rest character Text.

defrule string_syntax (character "\"") ["\\\""].
defrule string_syntax (character "\\") ["\\\\"].
defrule string_syntax (character "\n") ["\\n"].
defrule string_syntax (character "\t") ["\\t"].
defrule string_syntax (character "\r") ["\\r"].
defrule string_syntax (character "#") ["\\#"].
defrule string_syntax (character "#") ["#", unless "{"].
defrule string_syntax (character Char)
[char Char, where [Char] {dif Char "\"", dif Char "\\", dif Char "#"}].

defrule string_syntax (symbol_char Char) [next, where [Char] {dif Char "\""}].

@term_syntax #{
  super => [map_syntax, list_syntax, number_syntax, variable_syntax, string_syntax],
  metaclass => grammar
}.

value >> print_object
| Self Text |
ground Self,
parse term_syntax (expr Self) Text.

map >> print_object
| Self Text |
ground Self,
parse term_syntax (expr Self) Text.

string >> print_object
| Self Self |.

string >> print
| Self |
print Self Effect,
await Effect.

string >> print
| Self Effect |
new effect #{
  provider => output,
  operation => print,
  arguments => [Self]
} Effect.

@format_syntax #{super => syntax, metaclass => grammar}.

string >> format
| Self Args Text |
parse format_syntax (template Args Fragments []) Self,
join_text Fragments Text.

string >> format
| Self Args |
format Self Args Text,
print Text.

defrule format_syntax (template [] Tail Tail) [].
defrule format_syntax (template Args [Text . Output] Tail)
[text literal_char literal_char Text, unless (literal_char _), template Args Output Tail].
defrule format_syntax (template Args ["~" . Output] Tail)
["~~", template Args Output Tail].
defrule format_syntax (template Args ["\n" . Output] Tail)
["~%", template Args Output Tail].
defrule format_syntax (template [Value . Args] [Text . Output] Tail)
["~a", where [Value, Text] {print_object Value Text}, template Args Output Tail].

defrule format_syntax (literal_char Char)
[char Char, where [Char] {dif Char "~"}].

@declaration_syntax #{super => lisp_syntax, metaclass => grammar}.

defrule declaration_syntax (declaration (defclass Name Metaclass Super Ivars Categories))
[known_text,
  class_marker,
  symbol Name,
  gap,
  options Options,
  blanks,
  ".",
  where [Options, Pairs] {map_pairs Options Pairs},
  within Pairs [class_entries Metaclass Super Ivars Categories]].
defrule declaration_syntax (declaration (defclass Name Metaclass Super Ivars Categories))
[unknown_text,
  where [Options, Pairs] {map_pairs Options Pairs},
  within Pairs [class_entries Metaclass Super Ivars Categories],
  class_marker,
  symbol Name,
  gap,
  options Options,
  blanks,
  "."].
defrule declaration_syntax (declaration (extend_class Name Supers))
["@+", symbol Name, gap, extension_options Supers, blanks, "."].

defrule declaration_syntax class_marker ["@", known_text, unless "+"].
defrule declaration_syntax class_marker ["@", unknown_text].

defrule declaration_syntax (class_entries Metaclass Super Ivars Categories)
[optional categories Categories [],
  optional ivars Ivars [],
  optional metaclass Metaclass class,
  [[super, Super]]].

defrule declaration_syntax (optional _Key Default Default) [].
defrule declaration_syntax (optional Key Value _Default) [[[Key, Value]]].

defrule declaration_syntax (options Options) [expr Options, where [Options] {class Options map}].

defrule declaration_syntax (extension_options Supers)
[expr #{super => Supers}, where [Supers] {class Supers list}].
defrule declaration_syntax (extension_options [Super])
[expr #{super => Super}, where [Super] {not (class Super list)}].

@method_syntax #{super => block_syntax, metaclass => grammar}.

defrule method_syntax (clause (defmethod Owner Selector Head Body))
[symbol Owner, gap, ">>", gap, symbol Selector, line, "|", head Head, "|", body Body, blanks, "."].

defrule method_syntax (head []) [gap].
defrule method_syntax (head [Arg . Args]) [gap, expr Arg, head_rest Args, gap].
defrule method_syntax (head_rest []) [].
defrule method_syntax (head_rest [Arg . Args]) [gap, expr Arg, head_rest Args].
defrule method_syntax (head_rest Tail) [gap, ".", gap, expr Tail].

defrule method_syntax (body []) [].
defrule method_syntax (body [Goal . Goals]) [line, goal Goal, body_rest Goals].
defrule method_syntax (body_rest []) [].
defrule method_syntax (body_rest [Goal . Goals]) [blanks, ",", line, goal Goal, body_rest Goals].

defrule method_syntax line [unknown_text, "\n"].
defrule method_syntax line [known_text, blanks].

defrule method_syntax (symbol_char Char) [next, where [Char] {dif Char "|"}].

@al_grammar
#{super => [method_syntax, declaration_syntax, term_syntax], metaclass => grammar}.

defrule al_grammar (program Items) [blanks, zero_or_more item Items].
defrule al_grammar (item Item) [declaration Item, blanks].
defrule al_grammar (item Item) [clause Item, blanks].
