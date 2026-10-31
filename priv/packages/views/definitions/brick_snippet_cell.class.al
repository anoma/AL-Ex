@brick_snippet_cell
#{super => brick_snippet}.

brick_snippet_cell >> make_editor
| _Self Editor |
new brick_editor_cell #{font_size => 16, grammar => "al", is_read_only => false} Editor.
