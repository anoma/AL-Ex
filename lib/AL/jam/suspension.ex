defmodule AL.JAM.Suspension do
  def park(suspensions, variables, items) do
    items = Enum.map(items, &{make_ref(), &1})

    Enum.reduce(variables, suspensions, fn variable, suspensions ->
      Map.update(suspensions, variable, items, &(&1 ++ items))
    end)
  end

  def ready(suspensions, store) do
    {pending, ready} =
      Enum.reduce(Map.keys(suspensions), {suspensions, []}, fn variable, {pending, ready} ->
        case Map.fetch(pending, variable) do
          :error ->
            {pending, ready}

          {:ok, items} ->
            target = AL.Var.deref(store, variable)

            cond do
              target == variable ->
                {pending, ready}

              AL.Var.var?(target) ->
                pending =
                  pending
                  |> Map.delete(variable)
                  |> Map.update(target, items, &(&1 ++ items))

                {pending, ready}

              true ->
                {Map.delete(pending, variable), items ++ ready}
            end
        end
      end)

    if ready == [] do
      {pending, []}
    else
      ready = Enum.uniq_by(ready, &elem(&1, 0))
      resumed = MapSet.new(ready, &elem(&1, 0))

      pending =
        Map.new(
          Enum.flat_map(pending, fn {variable, items} ->
            case Enum.reject(items, fn {id, _} -> MapSet.member?(resumed, id) end) do
              [] -> []
              remaining -> [{variable, remaining}]
            end
          end)
        )

      {pending, Enum.map(ready, &elem(&1, 1))}
    end
  end
end
