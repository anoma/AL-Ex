@brick_editable_snippet
#{super => brick_snippet, ivars => [#{name => edit}]}.

brick_editable_snippet >> buttons
| Self [Save, Revert] |
action_button Self save_action "M0,5 L2,3 L5,6 L10,0 L12,2 L5,10 Z" "Save changes" Save,
action_button Self revert_action
  "M1,0 L6,5 L11,0 L12,1 L7,6 L12,11 L11,12 L6,7 L1,12 L0,11 L5,6 L0,1 Z"
  "Revert changes" Revert,
edited_binding Self Edited,
set_slot Save is_visible Edited,
set_slot Revert is_visible Edited.

brick_editable_snippet >> above
| Self [Error] |
edit_binding Self error Message,
new brick_text_block #{text => Message, foreground => "#D45555", font_size => 12, text_wrapping => "Wrap"} Error.

brick_editable_snippet >> make_editor
| Self Editor |
edit_binding Self text Text,
edit_binding Self original_text Original,
edit_binding Self grammar Grammar,
new brick_editor #{
  text => Text,
  original_text => Original,
  grammar => Grammar,
  font_size => 16,
  is_read_only => false,
  follow_caret => true,
  vertical_scroll_bar_visibility => "Disabled",
  horizontal_scroll_bar_visibility => "Disabled"
} Editor,
set_slot Editor name "snippet_editor".

brick_editable_snippet >> make_grid
| Self Editor Grid |
call_next_method Self Editor Grid,
edited_binding Self Edited,
set_slot Grid class_bindings #{edited => Edited}.

brick_editable_snippet >> indicator_styles
| Self Styles |
call_next_method Self Base,
new brick_setter #{property => "Background", value => "#D6AA28"} Yellow,
new brick_style #{
  selector => "Grid.snippet.edited > Border.indicator",
  setters => [Yellow]
} Edited,
concat Base [Edited] Styles.

brick_editable_snippet >> edit_binding
| Self Path Binding |
get Self edit Edit,
new brick_slot_binding #{object_id => Edit, path => Path} Binding.

brick_editable_snippet >> edited_binding
| _Self Binding |
new brick_binding #{element_name => "snippet_editor", path => "(editor:Code.IsModified)"} Binding.

brick_editable_snippet >> action_button
| Self Action Data Label Button |
edit_binding Self Action Command,
edit_binding Self can_save CanSave,
new brick_path_icon #{data => Data, width => 10, height => 10} Icon,
new brick_dynamic_resource #{resource_key => "SystemControlForegroundBaseMediumLowBrush"} Outline,
new brick_button #{
  command => Command,
  is_enabled => CanSave,
  content => Icon,
  tool_tip => Label,
  automation_name => Label,
  min_width => 28,
  min_height => 20,
  padding => "5,2",
  background => "Transparent",
  border_brush => Outline,
  border_thickness => "1",
  corner_radius => "3"
} Button.
