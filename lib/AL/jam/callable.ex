defmodule AL.JAM.Callable do
  defmodule Template do
    defstruct [:matcher, :initial, :locals, :code, :head, :capture_slots]
  end

  def fetch(targets, site, head, body, store, branch) do
    head = dereference(head, store)
    body = dereference(body, store)

    {head, body} =
      if AL.JAM.IR.Closure.static?(body),
        do: {head, body},
        else: {AL.Var.subst(head, store), AL.Var.subst(body, store)}

    key = {:callable, site}

    {compiled, captures, targets} =
      case Map.get(targets, key) do
        {^head, ^body, compiled, captures} ->
          {compiled, captures, targets}

        _ ->
          {compiled, captures} = AL.JAM.Compiler.fetch_callable(head, body, branch)
          {compiled, captures, Map.put(targets, key, {head, body, compiled, captures})}
      end

    {compiled, environment(captures, store), targets}
  end

  def environment(captures, store) do
    scope = Integer.to_string(AL.fresh_scope())

    AL.Var.subst(captures, store, fn
      :"$_" -> :"$_"
      variable -> AL.Var.fresh(variable, scope)
    end)
  end

  def match(%Template{} = template, environment, args, store, branch) do
    slots = put_captures(template.capture_slots, environment, template.initial)

    case AL.JAM.Head.match(template.matcher, args, store, slots, branch) do
      {store, slots} ->
        slots =
          if template.locals == [] do
            slots
          else
            scope = Integer.to_string(AL.fresh_scope())

            Enum.reduce(template.locals, slots, fn {index, name}, slots ->
              put_elem(slots, index, AL.Var.fresh(name, scope))
            end)
          end

        {template.code, slots, store, %{}, [], template.head}

      nil ->
        nil
    end
  end

  defp put_captures([], [], slots), do: slots

  defp put_captures([index | indices], [value | values], slots),
    do: put_captures(indices, values, put_elem(slots, index, value))

  defp dereference(value, store),
    do: if(AL.Var.var?(value), do: AL.Var.deref(store, value), else: value)
end
