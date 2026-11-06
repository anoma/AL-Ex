list >> view
| Self Builder View |
call_next_method Self Builder View.

list >> view
| Self Builder View |
list Builder ListBuilder,
lambda [Item, Row] F (= Row #{text => Item, target => Item}),
map Self F ListRows,
new ListBuilder
  #{ title => "Items",
     priority => 20,
     columns => [#{cell => brick_text}],
     items => ListRows
   } View.