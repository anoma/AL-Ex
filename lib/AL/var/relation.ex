defmodule AL.Var.Relation do
  alias AL.Var.ConstraintSet

  @type propagator() :: {:relation, :method | :clause, [AL.Var.t()]}

  def post(store, operation, arguments),
    do: register(store, {:relation, operation, arguments})

  def resolve(store, {:relation, operation, arguments} = prop, branch) do
    variables = variables(store, arguments)
    store = unregister(store, variables, prop)
    resolved = AL.Var.subst(arguments, store)

    matches =
      operation
      |> rows(arguments, store, branch)
      |> Enum.map(&AL.Var.unify(resolved, &1, store, branch))
      |> Enum.reject(&is_nil/1)

    case matches do
      [] ->
        nil

      [only] ->
        {only, MapSet.new()}

      _ ->
        case bind_common_values(store, variables, matches, branch) do
          nil ->
            nil

          next ->
            more =
              variables
              |> Enum.filter(&(Map.get(store, &1) != Map.get(next, &1)))
              |> Enum.flat_map(fn variable ->
                case AL.Var.constraint_set(store, variable) do
                  nil -> [prop]
                  set -> [prop | set.props]
                end
              end)
              |> MapSet.new()

            {register(next, prop), more}
        end
    end
  end

  defp rows(:method, arguments, store, branch) do
    [object, name, id] = AL.Var.subst(arguments, store)

    AL.Object.scan_method(object, name, id, branch)
    |> Enum.map(fn {:method, object, name, id} -> [object, name, id] end)
  end

  defp rows(:clause, [object, seq, head, body], store, branch) do
    AL.JAM.Clauses.reflect_clauses(
      AL.Var.subst(object, store),
      AL.Var.subst(seq, store),
      head,
      body,
      branch
    )
    |> Enum.map(fn row ->
      {:oapply, object, seq, head, body} = AL.standardize_apart(row)
      [object, seq, head, body]
    end)
  end

  defp bind_common_values(store, variables, matches, branch) do
    Enum.reduce_while(variables, store, fn variable, acc ->
      values = matches |> Enum.map(&AL.Var.subst(variable, &1)) |> Enum.uniq()

      case values do
        [only] ->
          if MapSet.size(AL.Var.find_vars(only)) == 0 do
            case AL.Var.unify(variable, only, acc, branch) do
              nil -> {:halt, nil}
              next -> {:cont, next}
            end
          else
            {:cont, acc}
          end

        _ ->
          {:cont, acc}
      end
    end)
  end

  def enumerate(variable, store, branch) do
    prop =
      case AL.Var.constraint_set(store, variable) do
        nil -> nil
        set -> Enum.find(set.props, &match?({:relation, _, _}, &1))
      end

    case prop do
      nil ->
        nil

      {:relation, operation, arguments} ->
        probe = unregister(store, variables(store, arguments), prop)
        resolved = AL.Var.subst(arguments, probe)

        values =
          operation
          |> rows(arguments, probe, branch)
          |> Enum.map(&AL.Var.unify(resolved, &1, probe, branch))
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&AL.Var.subst(variable, &1))
          |> Enum.uniq()

        if Enum.any?(values, &AL.Var.var?/1) do
          nil
        else
          values
          |> Enum.map(&AL.Var.unify(variable, &1, store, branch))
          |> Enum.reject(&is_nil/1)
        end
    end
  end

  defp variables(store, arguments) do
    arguments
    |> AL.Var.subst(store)
    |> AL.Var.find_vars()
    |> MapSet.delete({:"$var", "_"})
    |> MapSet.to_list()
  end

  defp register(store, {:relation, _operation, arguments} = prop) do
    Enum.reduce(variables(store, arguments), store, fn variable, acc ->
      Map.update(acc, variable, %ConstraintSet{props: [prop]}, fn set ->
        %{set | props: Enum.uniq([prop | set.props])}
      end)
    end)
  end

  defp unregister(store, variables, prop) do
    Enum.reduce(variables, store, fn variable, acc ->
      case Map.get(acc, variable) do
        %ConstraintSet{} = set ->
          Map.put(acc, variable, %{set | props: Enum.reject(set.props, &(&1 == prop))})

        _ ->
          acc
      end
    end)
  end
end
