defmodule AL.Views do
  @doc """
  I define GlamorousToolkit views for AL
  """

  
  use AL
  use GtBridge.View

  alias GtBridge.Phlow.Mondrian

  defview object_examine_view(self = %AL.Object{}, builder) do
    {:atomic, {bindings, _program_state}} = AL.run do
      examine(^self.id, info)
    end

    GtBridge.Views.MapGraph.graph(Map.get(bindings, :"$info"), builder)
    |> Mondrian.title("Examine")
  end

  defview cell_view(self = %AL.Object{}, builder) do
    result = AL.run do
      class(^self.id, :cell)
      get_slot(^self.id, :subscribers, subscribers)
      get_slot(^self.id, :value, value)
      unify(nodes, [^self.id | subscribers])
      unify(children, %{^self.id => subscribers})
    end
    case result do
      {:atomic, {bindings, _program_state}} ->
        builder.mondrian()
        |> Mondrian.title("Cell View")
        |> Mondrian.nodes(Enum.map(Map.get(bindings, :"$nodes"),
              fn x -> %AL.Object{id: x} end))
        |> Mondrian.node_label(fn node -> Atom.to_string(node.id) end)
        |> Mondrian.edges(fn node -> case Map.get(Map.get(bindings, :"$children"), node.id) do
                                       nil -> []
                                       children -> Enum.map(children, fn c -> %AL.Object{id: c} end)
                                     end
        end)
        |> Mondrian.layout(:horizontal_tree)
      _e -> builder.empty()
    end
  end

  defview propagator_view(self = %AL.Object{}, builder) do
    result = AL.run do
      class(^self.id, :propagator)
      get_slot(^self.id, :input_cells, input_cells)
      get_slot(^self.id, :output_cell, output_cell)
      unify(nodes, [^self.id | [output_cell | input_cells]])
      fold_left(input_cells, [acc, h, result],
                [put(acc, h, [^self.id], result)],
                %{^self.id => [output_cell]}, children)
    end

    IO.inspect(result)
    
    case result do
      {:atomic, {bindings, _program_state}} ->
        
        builder.mondrian()
        |> Mondrian.title("Propagator View")
        |> Mondrian.nodes(Enum.map(Map.get(bindings, :"$nodes"),
              fn x -> %AL.Object{id: x} end))
        |> Mondrian.node_label(fn node -> Atom.to_string(node.id) end)
        |> Mondrian.edges(fn node -> case Map.get(Map.get(bindings, :"$children"), node.id) do
                                       nil -> []
                                       children -> Enum.map(children, fn c -> %AL.Object{id: c} end)
                                     end
        end)
        |> Mondrian.layout(:horizontal_tree)
      _e -> builder.empty()
    end
  end  
end  
