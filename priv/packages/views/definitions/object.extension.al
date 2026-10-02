Extension {
  #name : :object
}

:object >> :view, [self, builder, view] [
  csharp_forward(builder, forward_builder)
  new(forward_builder, %{view: "aguil_raw", title: "Raw", target: self}, view)
]

:object >> :view, [self, builder, view] [
  list(builder, list_builder)
  class(self, class)

  findall(text, rows) do
    method(class, _n, id)
    vm_method_source(id, _seq, text, _prov)
  end

  new(list_builder,
      %{title: "meta",
        priority: 50,
        items: rows,
        columns: [%{title: "Body", element: "editor", grammar: "elixir"}]},
      view)
]

:object >> :view, [self, builder, view] [
  list(builder, list_builder)
  class(self, class)

  new(:anonymous_method, %{args: [], head: [x, res], body: [res = %{text: x, target: x}]}, to_entry)

  reachable_classes([class], [], inheritance_chain)
  map(inheritance_chain, to_entry, entries)

  new(list_builder,
      %{title: "Inheritance",
        priority: 30,
        items: entries,
        columns: [%{element: "text", title: "Class"}]},
      view)
]