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
    #{name => can_save, domain => [false, true]},
    #{name => error, type => string}
  ]
}.

source_edit >> init
| Self Args Self |
call_next_method Self Args Self,
get Self source_record Source,
get_slots Source #{text => Text, grammar => Grammar},
lambda [] Revert (revert Self),
lambda [] Save (save Self),
set_slots Self #{
  text => Text, original_text => Text, grammar => Grammar,
  revert_action => Revert, save_action => Save, can_save => true, error => ""
}.

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
get Previous text Baseline,
= Text Baseline -> {
  get_slots Source #{text => Updated, grammar => Grammar},
  set_slots Self #{source_record => Source, text => Updated, original_text => Updated, grammar => Grammar}
} ; pass.
