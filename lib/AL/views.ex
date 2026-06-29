defmodule AL.Views do
  @doc """
  I define GlamorousToolkit views for AL
  """

  use AL
  use GtBridge.View

  alias GtBridge.Phlow.Mondrian

  defview object_examine_view(self = %AL.Object{}, builder) do
    {:atomic, {bindings, _program_state}} =
      AL.run do
        examine(^self.id, info)
      end

    GtBridge.Views.MapGraph.graph(Map.get(bindings, :"$info"), builder)
    |> Mondrian.title("Examine")
  end

  defview constraint_view(self = %AL.Object{}, builder) do
    result =
      AL.run do
        dependents(^self.id, dependents)
      end

    case result do
      {:atomic, {bindings, _program_state}} ->
        dependents = Map.get(bindings, :"$dependents")

        builder.mondrian()
        |> Mondrian.title("Constraint Graph")
        |> Mondrian.nodes(
          dependents
          |> Map.keys()
          |> Enum.map(fn x -> %AL.Object{id: x} end)
        )
        |> Mondrian.node_label(fn node -> Atom.to_string(node.id) end)
        |> Mondrian.edges(fn node ->
          Map.get(dependents, node.id)
          |> Enum.map(fn c -> %AL.Object{id: c} end)
        end)
        |> Mondrian.layout(:horizontal_tree)

      _e ->
        builder.empty()
    end
  end
end
