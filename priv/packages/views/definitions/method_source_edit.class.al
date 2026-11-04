@method_source_edit
#{
  super => source_edit,
  ivars => [
    #{name => methods_view},
    #{name => package_options, type => observable_list},
    #{name => package_index, type => number},
    #{name => delete_action},
    #{name => confirm_delete_action},
    #{name => cancel_delete_action},
    #{default => false, domain => [false, true], name => delete_pending},
    #{name => previous_action},
    #{name => next_action}
  ]
}.

method_source_edit >> init
| Self Args Self |
call_next_method Self Args Self,
get Self methods_view View,
refresh_packages Self,
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

method_source_edit >> refresh
| Self Source |
call_next_method Self Source,
refresh_packages Self.

method_source_edit >> refresh_packages
| Self |
get_slots Self #{source_record => Source, methods_view => View},
package_options View Source Options,
get Self package_options Options -> pass ; set_slot Self package_options Options,
get Options contents Choices,
package Source Current -> {at Choices Index Choice, get Choice target Current} ; = Index -1,
get Self package_index Index -> pass ; set_slot Self package_index Index.

method_source_edit >> set_slot
| Self package_index -1 |
get Self source_record Source,
not (package Source _),
cut,
call_next_method Self package_index -1.

method_source_edit >> set_slot
| Self package_index Index |
>= Index 0,
cut,
get_slots Self #{package_options => Options, source_record => Source},
get Options contents Choices,
at Choices Index Choice,
get Choice target Package,
package Source Package -> call_next_method Self package_index Index ; {
  set_package Source Package,
  call_next_method Self package_index Index,
  get Self methods_view View,
  refresh View
}.

method_source_edit >> set_slot
| Self Key Value |
dif Key package_index,
call_next_method Self Key Value.
