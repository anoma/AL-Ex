@method_source_edit
#{
  super => source_edit,
  ivars => [
    #{name => methods_view},
    #{name => delete_action},
    #{name => confirm_delete_action},
    #{name => cancel_delete_action},
    #{name => delete_pending, default => false, domain => [false, true]},
    #{name => previous_action},
    #{name => next_action}
  ]
}.

method_source_edit >> init
| Self Args Self |
call_next_method Self Args Self,
get Self methods_view View,
lambda [] Delete (delete Self),
lambda [] Confirm (confirm_delete Self),
lambda [] Cancel (cancel_delete Self),
lambda [] Previous (navigate View Self -1),
lambda [] Next (navigate View Self 1),
set_slots Self #{
  delete_action => Delete,
  confirm_delete_action => Confirm,
  cancel_delete_action => Cancel,
  previous_action => Previous,
  next_action => Next
}.

method_source_edit >> delete
| Self |
get Self can_save true,
set_slot Self delete_pending true.

method_source_edit >> cancel_delete
| Self |
set_slot Self delete_pending false.

method_source_edit >> confirm_delete
| Self |
get_slots Self #{can_save => true, delete_pending => true},
get_slots Self #{source_record => Source, methods_view => View},
delete Source,
set_slot Self delete_pending false,
refresh View.
