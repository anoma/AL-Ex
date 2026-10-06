defmodule AL.JAM.Callable do
  def fetch(targets, site, head, body, store, branch) do
    head = dereference(head, store)
    body = dereference(body, store)
    key = {:callable, site}

    case Map.get(targets, key) do
      {^head, ^body, dependencies, compiled} ->
        if Enum.all?(dependencies, fn {variable, value} ->
             AL.Var.deref(store, variable) == value
           end) do
          {compiled, targets}
        else
          compile(targets, key, head, body, store, branch)
        end

      {^head, ^body} ->
        compile(targets, key, head, body, store, branch)

      _ ->
        compiled = resolve(head, body, store, branch)
        {compiled, Map.put(targets, key, {head, body})}
    end
  end

  defp compile(targets, key, head, body, store, branch) do
    compiled = resolve(head, body, store, branch)
    dependencies = dependencies(AL.Var.find_vars([head, body]), store, %{})
    {compiled, Map.put(targets, key, {head, body, Map.to_list(dependencies), compiled})}
  end

  defp resolve(head, body, store, branch),
    do:
      AL.JAM.Compiler.fetch_callable(AL.Var.subst(head, store), AL.Var.subst(body, store), branch)

  defp dependencies(variables, store, found) do
    Enum.reduce(variables, found, fn variable, found ->
      if Map.has_key?(found, variable) do
        found
      else
        value = AL.Var.deref(store, variable)
        found = Map.put(found, variable, value)

        if value == variable,
          do: found,
          else: dependencies(AL.Var.find_vars(value), store, found)
      end
    end)
  end

  defp dereference(value, store),
    do: if(AL.Var.var?(value), do: AL.Var.deref(store, value), else: value)
end
