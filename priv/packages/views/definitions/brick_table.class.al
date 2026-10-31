@brick_table
#{
  super => [value, brick_control],
  ivars => [
    #{
      default => [],
      element_type => brick_table_column,
      name => columns,
      type => list,
      xaml => xaml_collection_property
    },
    #{default => 0, name => row_spacing},
    #{default => true, name => show_headers},
    #{
      default => #{class => brick_binding, converter => "al:Data.Items"},
      name => items_source,
      xaml => xaml_content_property
    }
  ]
}.

brick_table >> init
| Self Fields Table |
get Fields columns Columns -> pass ; = Columns [],
lambda [ColumnFields, Column] Build (new brick_table_column ColumnFields Column),
map Columns Build ColumnBricks,
put Fields columns ColumnBricks WithColumns,
call_next_method Self WithColumns Table.

brick_table >> to_xaml
| Self Text |
table_styles Self TableStyles,
get Self styles Styles,
concat TableStyles Styles Combined,
put Self styles Combined Table,
call_next_method Table Text,
cut.

brick_table >> xaml_tag
| _Self "TableView" |.

brick_table >> table_styles
| Self [Row, Cell, Header] |
get_slots Self #{row_spacing => Spacing, show_headers => Headers},
format "0,0,0,~a" [Spacing] Margin,
new brick_binding #{converter => "al:Data.Target"} Target,
lambda [Fields, Setter] Build (new brick_setter Fields Setter),
map [
  #{property => "phlow:InspectionTarget.Target", value => Target},
  #{property => "Padding", value => "0"},
  #{property => "Margin", value => Margin},
  #{property => "MinHeight", value => 0}
] Build RowSetters,
new brick_style #{selector => "TableViewRow", setters => RowSetters} Row,
new brick_setter #{property => "Padding", value => "0"} CellPadding,
new brick_style #{selector => "TableViewCell", setters => [CellPadding]} Cell,
new brick_setter #{property => "IsVisible", value => Headers} HeaderVisibility,
new brick_style #{
  selector => "TableView /template/ ScrollViewer#PART_ScrollViewer /template/ TableViewColumnHeadersPresenter",
  setters => [HeaderVisibility]
} Header.
