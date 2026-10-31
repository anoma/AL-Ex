@brick_table
#{
  super => [value, brick],
  ivars => [
    #{default => [], name => columns},
    #{default => 0, name => row_spacing},
    #{default => true, name => show_headers}
  ]
}.

brick_table >> to_xaml
| Self Text |
get_slots Self #{columns => Columns, row_spacing => Spacing, show_headers => Headers},
atom_string Headers HeaderText,
format "~a" [Spacing] SpacingText,
lambda [Fields, ColumnText] Render {
  new brick_table_column Fields Column,
  to_xaml Column ColumnText
},
map Columns Render Parts,
join Parts Body,
join ["<TableView ItemsSource=\"{Binding Converter={x:Static al:Data.Items}}\">
  <TableView.Styles>
    <Style Selector=\"TableViewRow\">
      <Setter Property=\"phlow:InspectionTarget.Target\" Value=\"{Binding Converter={x:Static al:Data.Target}}\"/>
      <Setter Property=\"Padding\" Value=\"0\"/>
      <Setter Property=\"Margin\" Value=\"0,0,0,", SpacingText, "\"/>
      <Setter Property=\"MinHeight\" Value=\"0\"/>
    </Style>
    <Style Selector=\"TableViewCell\"><Setter Property=\"Padding\" Value=\"0\"/></Style>
    <Style Selector=\"TableView /template/ ScrollViewer#PART_ScrollViewer /template/ TableViewColumnHeadersPresenter\">
      <Setter Property=\"IsVisible\" Value=\"", HeaderText, "\"/>
    </Style>
  </TableView.Styles>
  <TableView.Columns>", Body, "</TableView.Columns>
</TableView>"] Text.