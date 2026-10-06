defmodule AL.JAM.Suspension do
  def park(suspensions, variables, items) do
    Enum.reduce(variables, suspensions, fn variable, suspensions ->
      Map.update(suspensions, variable, items, &(&1 ++ items))
    end)
  end

  def ready(suspensions, store) do
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
  end
end
