defmodule AL.GtBridge do
  @moduledoc """
  I define GlamorousToolkit views for AL
  """

  use AL
  use GtBridge.View

  alias GtBridge.Phlow.Mondrian

  alias GtBridge.Phlow.ColumnedList

  def display_name(self = %AL.Object{}) do
    result =
      AL.run branch: AL.Object.branch_id(self) do
        vm_get_slot(^self.id, :name, name)
      end

    case result do
      {:atomic, {bindings, _}} ->
        case Map.get(bindings, :"$name") do
          name when is_binary(name) and name != "" -> name
          name when is_atom(name) and name not in [nil, false] -> Atom.to_string(name)
          _ -> object_label(self.id)
        end

      _ ->
        object_label(self.id)
    end
  end

  def object_info(self = %AL.Object{}) do
    branch = AL.Object.branch_id(self)

    result =
      AL.run branch: branch do
        examine(^self.id, info)
      end

    case result do
      {:atomic, {bindings, _}} ->
        info = Map.fetch!(bindings, :"$info")

        identity = [
          {"Identity", "ID", inspect(self.id), self},
          {"Identity", "Branch", to_string(branch), %AL.Branch{id: branch}}
        ]

        slots =
          info
          |> Map.get(:direct_slots, [])
          |> Enum.sort_by(fn [key, _] -> inspect(key) end)
          |> Enum.map(fn [key, value] -> {"Slots", object_label(key), inspect(value), value} end)

        identity ++ slots

      {:aborted, reason} ->
        [{"Status", "Unavailable", inspect(reason), reason}]
    end
  end

  defp object_label(id) when is_atom(id), do: Atom.to_string(id)
  defp object_label(id) when is_binary(id), do: id
  defp object_label(id), do: inspect(id)

  def object_title(self = %AL.Object{}), do: "AL.Object · #{inspect(self.id)}"

  @doc "Return the class and superclass DAG for an object on its branch."
  def inheritance_dag(self = %AL.Object{}) do
    branch = %AL.Branch{id: AL.Object.branch_id(self)}

    case :mnesia.transaction(fn -> inheritance_graph(self.id, branch) end) do
      {:atomic, graph} -> graph
      {:aborted, _reason} -> %{nodes: [self], edges: %{}, roles: %{self.id => :self}}
    end
  end

  defp inheritance_graph(self_id, branch) do
    class_ids = object_classes(self_id, branch)
    roots = class_ids
    {super_ids, super_edges} = collect_super_graph(roots, branch, MapSet.new(), %{}, [])
    ids = Enum.uniq([self_id | class_ids ++ super_ids])
    objects = Enum.map(ids, &%AL.Object{id: &1, branch: branch.id})

    child_edges =
      super_edges
      |> Map.update(self_id, class_ids, fn children ->
        Enum.uniq(children ++ class_ids)
      end)

    edges = invert_edges(child_edges)

    roles =
      Enum.reduce(ids, %{}, fn id, acc ->
        role =
          cond do
            id == self_id -> :self
            id in class_ids -> :class
            true -> :super
          end

        Map.put(acc, id, role)
      end)

    %{nodes: objects, edges: edges, roles: roles}
  end

  defp invert_edges(child_edges) do
    Enum.reduce(child_edges, %{}, fn {child, parents}, edges ->
      Enum.reduce(parents, edges, fn parent, acc ->
        Map.update(acc, parent, [child], fn children -> Enum.uniq(children ++ [child]) end)
      end)
    end)
  end

  defp object_classes(object, branch) do
    AL.Object.scan_class(object, :"$class", branch)
    |> Enum.map(fn {:class, ^object, _seq, class} -> class end)
    |> Enum.uniq()
  end

  defp collect_super_graph([], _branch, _visited, edges, ids), do: {Enum.reverse(ids), edges}

  defp collect_super_graph([object | rest], branch, visited, edges, ids) do
    if MapSet.member?(visited, object) do
      collect_super_graph(rest, branch, visited, edges, ids)
    else
      supers =
        AL.Object.scan_super(object, :"$super", branch)
        |> Enum.map(fn {:super, ^object, _seq, super} -> super end)
        |> Enum.uniq()

      next_ids =
        Enum.reduce(supers, ids, fn super, acc ->
          if super in acc, do: acc, else: [super | acc]
        end)

      next_edges = Map.put(edges, object, supers)
      next_roots = rest ++ Enum.reject(supers, &(&1 == :object))
      collect_super_graph(next_roots, branch, MapSet.put(visited, object), next_edges, next_ids)
    end
  end

  defview object_examine_view(self = %AL.Object{}, builder) do
    builder.columned_list()
    |> ColumnedList.title("Object")
    |> ColumnedList.priority(5)
    |> ColumnedList.items(object_info(self))
    |> ColumnedList.column("Property", fn
      {"Slots", property, _, _} -> "Slot · #{property}"
      {_, property, _, _} -> property
    end)
    |> ColumnedList.column("Value", fn {_, _, value, _} -> value end)
    |> ColumnedList.send(fn {_, _, _, target} -> target end)
  end

  def instances(self = %AL.Object{}) do
    branch = %AL.Branch{id: AL.Object.branch_id(self)}
    self_id = self.id

    case :mnesia.transaction(fn ->
           AL.Object.scan_class(:"$instance", self_id, branch)
           |> Enum.map(fn {:class, instance, _seq, ^self_id} ->
             %AL.Object{id: instance, branch: branch.id}
           end)
           |> Enum.uniq_by(& &1.id)
         end) do
      {:atomic, instances} -> instances
      {:aborted, _reason} -> []
    end
  end

  defview instances_view(self = %AL.Object{}, builder) do
    builder.columned_list()
    |> ColumnedList.title("Instances")
    |> ColumnedList.priority(7)
    |> ColumnedList.items(instances(self))
    |> ColumnedList.column("ID", fn instance -> object_label(instance.id) end)
    |> ColumnedList.send(fn instance -> instance end)
  end

  defview inheritance_dag_view(self = %AL.Object{}, builder) do
    graph = inheritance_dag(self)
    branch = AL.Object.branch_id(self)

    builder.mondrian()
    |> Mondrian.title("Inheritance DAG")
    |> Mondrian.priority(6)
    |> Mondrian.nodes(graph.nodes)
    |> Mondrian.node_label(fn node -> object_label(node.id) end)
    |> Mondrian.node_color(fn node -> inheritance_node_color(node.id, graph.roles[node.id]) end)
    |> Mondrian.edges(fn node ->
      graph.edges
      |> Map.get(node.id, [])
      |> Enum.map(fn id -> %AL.Object{id: id, branch: branch} end)
    end)
    |> Mondrian.layout(:tree)
  end

  defp inheritance_node_color(:object, _role), do: "#DC2626"
  defp inheritance_node_color(_id, role), do: inheritance_color(role)

  defp inheritance_color(:self), do: "#4F46E5"
  defp inheritance_color(:class), do: "#059669"
  defp inheritance_color(:super), do: "#D97706"
  defp inheritance_color(_role), do: "#94A3B8"

  def command_log_view(_builder, log, title) do
    rows = AL.Command.command_log_rows(log)
    %AL.GtBridge.CommandLogView{title: title, rows: rows}
  end

  defview transaction_commands_view(self = %AL.Object{}, builder) do
    branch = %AL.Branch{id: AL.Object.branch_id(self)}

    case transaction_slots(self) do
      {:ok, %{tx: tx}} ->
        case :mnesia.transaction(fn -> AL.Command.commands_for_transaction(tx, branch) end) do
          {:atomic, rows} -> command_log_view(builder, rows, "Transaction Commands")
          _ -> builder.empty()
        end

      _ ->
        builder.empty()
    end
  end

  defview transaction_source_view(self = %AL.Object{}, builder) do
    branch = %AL.Branch{id: AL.Object.branch_id(self)}

    result =
      case transaction_slots(self) do
        {:ok, %{tx: command_tx}} ->
          :mnesia.transaction(fn -> AL.SourceStore.text(command_tx, branch) end)

        _ ->
          :absent
      end

    case result do
      {:atomic, {:source_text, _, source, _}} ->
        builder.text()
        |> GtBridge.Phlow.Text.title("Retained Source")
        |> GtBridge.Phlow.Text.priority(8)
        |> GtBridge.Phlow.Text.string(source)

      _ ->
        builder.empty()
    end
  end

  defview transaction_failure_view(self = %AL.Object{}, builder) do
    case transaction_slots(self) do
      {:ok, %{status: :failed, reason: reason}} ->
        builder.columned_list()
        |> ColumnedList.title("Failure")
        |> ColumnedList.priority(8)
        |> ColumnedList.items(transaction_failure_rows(reason))
        |> ColumnedList.column("Property", fn {property, _value} -> property end)
        |> ColumnedList.column("Value", fn {_property, value} -> value end)

      _ ->
        builder.empty()
    end
  end

  defp transaction_slots(self = %AL.Object{}) do
    branch = %AL.Branch{id: AL.Object.branch_id(self)}

    case :mnesia.transaction(fn ->
           if AL.Object.scan_class(self.id, :transaction, branch) == [] do
             :not_transaction
           else
             case AL.Object.read_slots(self.id, branch) do
               [{:slots, _, slots}] -> {:ok, slots}
               _ -> :unavailable
             end
           end
         end) do
      {:atomic, result} -> result
      _ -> :unavailable
    end
  end

  defp transaction_failure_rows(reason) when is_map(reason) do
    []
    |> maybe_failure_row("Message", Map.get(reason, :message), &to_string/1)
    |> maybe_failure_row("Reason", Map.get(reason, :reason), &inspect/1)
    |> maybe_failure_row("Failed On", Map.get(reason, :failed_on), &inspect/1)
    |> maybe_failure_row("Trace", Map.get(reason, :trace), fn trace ->
      trace |> Enum.map(&inspect/1) |> Enum.join("\n")
    end)
  end

  defp transaction_failure_rows(reason), do: [{"Reason", inspect(reason)}]

  defp maybe_failure_row(rows, _property, nil, _format), do: rows
  defp maybe_failure_row(rows, property, value, format), do: rows ++ [{property, format.(value)}]

  defview constraint_view(self = %AL.Object{}, builder) do
    result =
      AL.run branch: AL.Object.branch_id(self) do
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
          |> Enum.map(fn x -> %AL.Object{id: x, branch: AL.Object.branch_id(self)} end)
        )
        |> Mondrian.node_label(fn node -> Atom.to_string(node.id) end)
        |> Mondrian.edges(fn node ->
          Map.get(dependents, node.id, [])
          |> Enum.map(fn c -> %AL.Object{id: c, branch: AL.Object.branch_id(self)} end)
        end)
        |> Mondrian.layout(:horizontal_tree)

      _e ->
        builder.empty()
    end
  end
end
