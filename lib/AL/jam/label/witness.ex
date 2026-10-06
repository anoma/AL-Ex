defmodule AL.JAM.Label.Witness do
  @moduledoc false

  alias AL.Goal

  def objects(object, candidate_classes, pending_classes, store, branch) do
    durable(object, candidate_classes, pending_classes, store, branch) ++
      values(object, candidate_classes, pending_classes, store, branch)
  end

  def classes(class, object, relation, store, branch) do
    branch
    |> exact_classes()
    |> Enum.map(fn candidate ->
      relation_goal =
        case relation do
          :class -> %Goal.GetClass{object: object, class: candidate}
          :isa -> %Goal.Isa{object: object, class: candidate}
        end

      {store, [relation_goal, %Goal.Eq{a: class, b: candidate}]}
    end)
  end

  defp durable(object, candidate_classes, pending_classes, store, branch) do
    branch
    |> AL.Dispatch.durable_classes()
    |> Enum.flat_map(fn {identity, classes} ->
      classes
      |> Enum.filter(&eligible_class?(candidate_classes, &1))
      |> Enum.map(fn class ->
        with next when not is_nil(next) <- AL.Var.unify(object, identity, store, branch),
             next when not is_nil(next) <-
               bind_pending_classes(next, pending_classes, class, branch) do
          {next, []}
        end
      end)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp values(object, candidate_classes, pending_classes, store, branch) do
    candidate_classes
    |> candidate_class_list(branch)
    |> Enum.filter(&value_class?(&1, branch))
    |> Enum.map(fn class ->
      with {next, _classes} <- AL.Var.add_direct_class(store, object, class),
           false <- AL.Var.direct_class_conflict?(next, object),
           true <- dispatch_compatible?(next, object, class, branch),
           next when not is_nil(next) <-
             bind_pending_classes(next, pending_classes, class, branch) do
        {next,
         [
           %Goal.Send{object: class, method: :witness, args: [object]},
           %Goal.Not{condition: [%Goal.IsVar{term: object}]}
         ]}
      else
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
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
end
