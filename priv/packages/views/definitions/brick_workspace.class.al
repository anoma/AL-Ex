@brick_workspace
#{super => [value, brick_items_control], ivars => [#{name => target}]}.

brick_workspace >> init
| Self Fields Workspace |
get Fields target Layout,
new brick_slot_binding #{object_id => Layout, path => "windows"} Windows,
new brick_panel #{} Panel,
put Fields items_source Windows WithSource,
put WithSource items_panel Panel WithPanel,
call_next_method Self WithPanel Workspace.