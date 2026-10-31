@brick_method_snippet
#{super => brick_editable_snippet}.

brick_method_snippet >> init
| Self Args Self |
new brick_binding #{converter => "al:Data.Field", converter_parameter => "edit"} Edit,
put Args edit Edit Fields,
call_next_method Self Fields Self.

brick_method_snippet >> buttons
| Self Buttons |
call_next_method Self Base,
action_button Self delete_action
  "M2,3 L10,3 L9,12 L3,12 Z M0,1 L4,1 L4,0 L8,0 L8,1 L12,1 L12,2 L0,2 Z"
  "Delete method" Delete,
delete_confirmation Self Confirmation,
concat Base [Delete, Confirmation] Buttons.

brick_method_snippet >> delete_confirmation
| Self Panel |
edit_binding Self delete_pending Pending,
new brick_text_block #{
  text => "Delete method?", font_size => 12, vertical_alignment => "Center"
} Label,
action_button Self confirm_delete_action
  "M0,5 L2,3 L5,6 L10,0 L12,2 L5,10 Z" "Confirm deletion" Confirm,
action_button Self cancel_delete_action
  "M1,0 L6,5 L11,0 L12,1 L7,6 L12,11 L11,12 L6,7 L1,12 L0,11 L5,6 L0,1 Z"
  "Cancel deletion" Cancel,
new brick_stack_panel #{
  children => [Label, Confirm, Cancel],
  orientation => "Horizontal",
  spacing => 3,
  is_visible => Pending
} Panel.
