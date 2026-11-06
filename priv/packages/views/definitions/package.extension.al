package >> view
| Self Builder View |
active_build Self Build,
originated_classes Build Classes,
lambda [Class, Row] ToRow (= Row #{target => Class, text => Class}),
map Classes ToRow Rows,
list Builder ListBuilder,
new ListBuilder #{
  columns => [#{cell => brick_text, header => "Class"}],
  items => Rows,
  priority => 10,
  title => "Classes"
} View.

package >> view
| Self Builder View |
call_next_method Self Builder View.