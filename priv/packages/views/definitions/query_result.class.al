@query_result
#{
  super => value,
  ivars => [
    #{name => bindings, type => list},
    #{name => constraints, type => list},
    #{name => store, type => list}
  ]
}.

query_result >> view
| Self _Builder View |
get_slots Self #{bindings => Bindings, constraints => Constraints, store => Store},
rows Self Bindings "=" BindingRows,
rows Self Constraints ":" ConstraintRows,
rows Self Store "=>" StoreRows,
concat BindingRows ConstraintRows First,
concat First StoreRows Rows,
findall Binding CellBindings {
  member ["name", "separator", "value"] Field,
  new brick_binding #{converter => "al:Data.Field", converter_parameter => Field} Binding
},
new brick_multi_binding #{bindings => CellBindings, string_format => "{0} {1} {2}"} Text,
new phlow_clist #{
  columns => [#{cell => brick_editor_cell, text => Text}],
  items => Rows,
  priority => 100,
  show_headers => false,
  title => "Raw"
} View.

query_result >> view
| Self _Builder View |
get Self bindings Bindings,
member Bindings [Name, Value],
var Value,
new phlow_text #{priority => 200, text => "Unbound variable", title => Name} View.

query_result >> view
| Self _Builder View |
get Self bindings Bindings,
member Bindings [Name, Value],
not {var Value},
new phlow_views #{priority => 200, target => Value, title => Name} View.

query_result >> rows
| _Self [] _Separator [] |.

query_result >> rows
| Self [[Name, Value] . Rest] Separator [
  #{name => Name, separator => Separator, target => Value, value => Value} . Rows
] |
rows Self Rest Separator Rows.
