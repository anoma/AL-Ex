@source_edit
#{
  super => object,
  ivars => [
    #{name => source_record, type => source_text},
    #{name => text, type => string},
    #{name => original_text, type => string},
    #{name => grammar, type => string},
    #{name => revert_action},
    #{name => save_action},
    #{name => folds, type => list},
    #{name => fold_action},
    #{domain => [false, true], name => can_save},
    #{name => error, type => string}
  ]
}.

source_edit >> init
| Self Args Self |
new snippet_fold #{} Default,
get Args folds [Default] Folds,
put Args folds Folds Fields,
call_next_method Self Fields Self,
get Self source_record Source,
get_slots Source #{text => Text, grammar => Grammar},
lambda [] Revert (revert Self),
lambda [] Save (save Self),
lambda [] Fold (toggle_fold Self),
set_slots Self #{
  text => Text, original_text => Text, grammar => Grammar,
  revert_action => Revert, save_action => Save, fold_action => Fold,
  can_save => true, error => ""
}.

source_edit >> toggle_fold
| Self |
get Self folds Folds,
lambda [Fold, UpdatedFold] Toggle {
  get Fold folded true -> put Fold folded false UpdatedFold ; put Fold folded true UpdatedFold
},
map Folds Toggle Updated,
set_slot Self folds Updated.

source_edit >> set_slot
| Self Key Value |
call_next_method Self Key Value,
member [text, folds] Key -> {
  get_slots Self #{text => Text, folds => Folds} -> {
    lambda [Fold, UpdatedFold] Refresh {refresh Fold Text UpdatedFold},
    map Folds Refresh Updated,
    call_next_method Self folds Updated
  } ; pass
} ; pass.

source_edit >> save
| Self |
get_slots Self #{source_record => Source, text => Text, can_save => true},
set_slots Self #{can_save => false, error => ""},
save Source Text Self.

source_edit >> saved
| Self Source Submitted |
current Source Current,
get_slots Current #{text => Original, grammar => Grammar},
get Self text Draft,
= Draft Submitted -> set_slot Self text Original ; pass,
set_slots Self #{source_record => Current, original_text => Original, grammar => Grammar}.

source_edit >> save_finished
| Self #{status => ok, value => _Transaction} |
set_slots Self #{can_save => true, error => ""}.

source_edit >> save_finished
| Self #{status => error, reason => Reason} |
isa Reason string -> = Message Reason ; format "~p" [Reason] Message,
set_slots Self #{can_save => true, error => Message}.

source_edit >> revert
| Self |
get Self can_save true,
get Self source_record Source,
current Source Current,
get_slots Current #{text => Text, grammar => Grammar},
set_slots Self #{source_record => Current, text => Text, original_text => Text, grammar => Grammar, error => ""}.

source_edit >> refresh
| Self Source |
get_slots Self #{source_record => Previous, text => Text},
= Source Previous -> pass ; {
  get Previous text Baseline,
  = Text Baseline -> {
    get_slots Source #{text => Updated, grammar => Grammar},
    set_slots Self #{
      source_record => Source,
      text => Updated,
      original_text => Updated,
      grammar => Grammar
    }
  } ; pass
}.
