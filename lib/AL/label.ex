defmodule AL.Label do
  @moduledoc false

  alias AL.Goal

  @spec object_choicepoints(AL.t(), AL.Var.t(), :any | [atom()], [AL.Var.t()]) ::
          [AL.Choicepoint.t()]
  def object_choicepoints(state, object, candidate_classes, pending_classes \\ []) do
    durable_choicepoints(state, object, candidate_classes, pending_classes) ++
      value_choicepoints(state, object, candidate_classes, pending_classes)
  end

  @spec class_choicepoints(AL.t(), AL.Var.t(), AL.Var.t(), :class | :isa) ::
          [AL.Choicepoint.t()]
  def class_choicepoints(state, class, object, relation) do
    state.branch
    |> exact_classes()
    |> Enum.map(fn candidate -> class_choicepoint(state, class, object, candidate, relation) end)
  end

  @spec install_choicepoints(AL.t(), [AL.Choicepoint.t()]) :: AL.t()
  def install_choicepoints(state, candidates) do
    case candidates do
      [] ->
        AL.backtrack(state)

      [first | rest] ->
        %AL{state | active_choicepoint: first, choicepoint_stack: rest ++ state.choicepoint_stack}
    end
  end

  defp durable_choicepoints(state, object, candidate_classes, pending_classes) do
    state.branch
    |> AL.Dispatch.durable_classes()
    |> Enum.flat_map(fn {identity, classes} ->
      classes
      |> Enum.filter(&eligible_class?(candidate_classes, &1))
      |> Enum.map(&durable_choicepoint(state, object, identity, &1, pending_classes))
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp durable_choicepoint(state, object, identity, class, pending_classes) do
    with store when not is_nil(store) <-
           AL.Var.unify(object, identity, state.active_choicepoint.store, state.branch),
         store when not is_nil(store) <-
           bind_pending_classes(store, pending_classes, class, state.branch) do
      %AL.Choicepoint{state.active_choicepoint | store: store}
    else
      nil -> nil
    end
  end

  defp value_choicepoints(state, object, candidate_classes, pending_classes) do
    candidate_classes
    |> candidate_class_list(state.branch)
    |> Enum.filter(&value_class?(&1, state.branch))
    |> Enum.map(&value_choicepoint(state, object, &1, pending_classes))
    |> Enum.reject(&is_nil/1)
  end

  defp value_choicepoint(state, object, class, pending_classes) do
    with {store, _classes} <-
           AL.Var.add_direct_class(state.active_choicepoint.store, object, class),
         false <- AL.Var.direct_class_conflict?(store, object),
         true <- dispatch_compatible?(store, object, class, state.branch),
         store when not is_nil(store) <-
           bind_pending_classes(store, pending_classes, class, state.branch) do
      goals =
        AL.splice_goals(state, [
          %Goal.Send{object: class, method: :witness, args: [object]},
          %Goal.Not{condition: [%Goal.IsVar{term: object}]}
        ])

      %AL.Choicepoint{state.active_choicepoint | goals: goals, store: store}
    else
      _ -> nil
    end
  end

  defp bind_pending_classes(store, pending_classes, class, branch) do
    Enum.reduce_while(pending_classes, store, fn pending, acc ->
      case AL.Var.unify(pending, class, acc, branch) do
        nil -> {:halt, nil}
        next -> {:cont, next}
      end
    end)
  end

  defp candidate_class_list(:any, branch), do: exact_classes(branch)
  defp candidate_class_list(classes, _branch), do: classes

  defp eligible_class?(:any, _class), do: true
  defp eligible_class?(classes, class), do: class in classes

  defp value_class?(class, branch) do
    :value in AL.Dispatch.MethodOrder.super_chain([class], branch, :dfs)
  end

  defp dispatch_compatible?(store, object, class, branch) do
    Enum.all?(AL.Var.dispatch_of(store, object), fn {selector, provider} ->
      AL.Dispatch.selected_provider_for_class(class, selector, branch) == provider
    end)
  end

  defp exact_classes(branch) do
    scope = AL.fresh_scope()

    declared =
      AL.Object.scan_class(AL.Var.var("label_class_#{scope}"), :class, branch)
      |> Enum.map(fn {:class, class, _seq, :class} -> class end)

    durable =
      branch
      |> AL.Dispatch.durable_classes()
      |> Enum.flat_map(fn {_object, classes} -> classes end)

    Enum.uniq(declared ++ durable)
  end

  defp class_choicepoint(state, class, object, candidate, relation) do
    relation_goal =
      case relation do
        :class -> %Goal.GetClass{object: object, class: candidate}
        :isa -> %Goal.Isa{object: object, class: candidate}
      end

    goals =
      AL.splice_goals(state, [
        relation_goal,
        %Goal.Eq{a: class, b: candidate}
      ])

    %AL.Choicepoint{state.active_choicepoint | goals: goals}
  end
end
