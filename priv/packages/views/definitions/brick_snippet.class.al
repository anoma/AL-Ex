@brick_snippet
#{
  super => brick,
  ivars => [
    #{name => source, type => string},
    #{name => editor, type => brick_editor},
    #{name => grid, type => brick_grid}
  ]
}.

brick_snippet >> init
| Self Args Self |
call_next_method Self Args Self,
make_editor Self Editor,
make_grid Self Editor Grid,
set_slots Self #{editor => Editor, grid => Grid}.

brick_snippet >> editor
| Self Editor |
get Self editor Editor.

brick_snippet >> handle_event
| _Self updated_source |.

brick_snippet >> above
| _Self [] |.

brick_snippet >> buttons
| _Self [] |.

brick_snippet >> to_xaml
| Self Text |
get Self grid Grid,
to_xaml Grid Text.

brick_snippet >> make_editor
| Self Editor |
get Self source Source,
new brick_editor #{text => Source, grammar => "al", is_read_only => false} Editor.

brick_snippet >> make_grid
| Self Editor Grid |
above Self Above,
buttons Self Buttons,
tags Self Tags,

new brick_stack_panel #{children => Above} Heading,
set_slot Editor grid_row 1,
new brick_stack_panel #{
  children => Buttons,
  orientation => "Horizontal",
  horizontal_alignment => "Left",
  spacing => 1
} Actions,
new brick_stack_panel #{
  children => Tags,
  grid_column => 1,
  orientation => "Horizontal",
  horizontal_alignment => "Right",
  spacing => 4
} Metadata,
new brick_column_definition #{width => "*"} ActionsColumn,
new brick_column_definition #{width => "Auto"} MetadataColumn,
new brick_grid #{
  classes => "actions",
  children => [Actions, Metadata],
  column_definitions => [ActionsColumn, MetadataColumn],
  grid_row => 2
} Footer,
new brick_row_definition #{height => "Auto"} HeadingRow,
new brick_row_definition #{height => "*"} EditorRow,
new brick_row_definition #{height => "Auto"} ActionsRow,
new brick_grid #{
  children => [Heading, Editor, Footer],
  row_definitions => [HeadingRow, EditorRow, ActionsRow],
  grid_column => 1,
  margin => "4"
} Body,

new brick_border #{classes => "indicator"} Indicator,
new brick_column_definition #{width => 4} MarkerColumn,
new brick_column_definition #{width => "*"} ContentColumn,
indicator_styles Self Indicators,
action_styles Self ActionsStyles,
concat Indicators ActionsStyles Styles,

new brick_grid #{
  background => "Transparent",
  classes => "snippet",
  children => [Indicator, Body],
  column_definitions => [MarkerColumn, ContentColumn],
  styles => Styles
} Grid.

brick_snippet >> indicator_styles
| _Self [Neutral, Focus] |
new brick_dynamic_resource #{
  resource_key => "SystemControlForegroundBaseLowBrush"
} Brush,
new brick_setter #{property => "Background", value => Brush} NeutralColor,
new brick_style #{
  selector => "Grid.snippet > Border.indicator",
  setters => [NeutralColor]
} Neutral,

new brick_setter #{property => "Background", value => "#3978C6"} FocusColor,
new brick_style #{
  selector => "Grid.snippet:focus-within > Border.indicator",
  setters => [FocusColor]
} Focus.

brick_snippet >> tags
| _Self [] |.

brick_snippet >> action_styles
| _Self [Hidden] |
new brick_setter #{property => "Opacity", value => 0} Transparent,
new brick_setter #{property => "IsHitTestVisible", value => false} Inert,
new brick_style #{
  selector => "Grid.snippet:not(:pointerover):not(:focus-within) Grid.actions",
  setters => [Transparent, Inert]
} Hidden.
