defmodule AL.Source do
  @moduledoc """
  I render AL goal patterns back into AL source the inverse of `AL.ast_to_pattern/1`.

  The source uses gensysms, and are converted to `a`, `b`, 。。。 before printing.

  Goals I don't recognise render as `RAW(<term>)` so there is something to see
  """

  @arith [:+, :-, :*, :/, :**]

  @doc """
  `[name, defmethod-source]` pairs for every method on `class`, decompiled from
  the stored clauses. The store-facing convenience over the pure printers above;
  this is what the GT method-coder view calls over the bridge.
  """
  @spec method_sources(atom(), AL.Branch.t() | atom()) :: [[String.t()]]
  def method_sources(class, branch \\ AL.Branch.head())

  def method_sources(class, id) when is_atom(id),
    do: method_sources(class, %AL.Branch{id: id})

  def method_sources(class, branch) do
    {:atomic, rows} =
      :mnesia.transaction(fn ->
        for {:method, _o, name, id} <- AL.Object.scan_method(class, :"$n", :"$id", branch) do
          source =
            id
            |> AL.Object.scan_oapply(:"$seq", :"$h", :"$b", branch)
            |> Enum.map(fn {:oapply, _id, _seq, h, b} -> defmethod_source(class, name, h, b) end)
            |> Enum.join("\n\n")

          [to_string(name), source]
        end
      end)

    rows
  end

  @doc "Source for one clause as `defmethod(class, name, head) do body end`."
  @spec defmethod_source(atom(), atom(), term(), [AL.goal()]) :: String.t()
  def defmethod_source(class, name, head, body) do
    {head, body} = rename({head, body})
    Macro.to_string({:defmethod, [], [pat(class), pat(name), pat(head), [do: goals(body)]]})
  end

  @doc "Source for a body as a do-block."
  @spec body_source([AL.goal()]) :: String.t()
  def body_source(body) do
    body
    |> rename()
    |> goals()
    |> Macro.to_string()
  end

  # --- rename gensym'd vars to a, b, c by first appearance ---
  @spec rename(term()) :: term()
  defp rename(term) do
    map =
      term
      |> collect()
      |> Enum.uniq()
      |> Enum.with_index()
      |> Map.new(fn {v, i} ->
        a = if i < 26, do: <<?a + i>>, else: "v#{i}"
        {v, AL.Var.var(a)}
      end)

    sub(term, map)
  end

  # Vars in first-appearance order (with dups; caller dedups).
  @spec collect(any()) :: [AL.Var.t()]
  defp collect(term) do
    AL.Goal.reduce(term, [], fn leaf, acc -> if AL.Var.var?(leaf), do: [leaf | acc], else: acc end)
    |> Enum.reverse()
  end

  @spec sub(term(), %{optional(atom()) => atom()}) :: term()
  defp sub(term, map), do: AL.Goal.map(term, fn leaf -> Map.get(map, leaf, leaf) end)

  # --- goals -> surface AST ---
  @spec goals([AL.goal()]) :: Macro.t()
  defp goals([]), do: {:__block__, [], []}
  defp goals([g]), do: goal(g)
  defp goals(gs), do: {:__block__, [], Enum.map(gs, &goal/1)}

  @spec goal(AL.goal()) :: Macro.t()
  defp goal(:cut), do: {:cut, [], []}
  defp goal(:fail), do: {:fail, [], []}
  defp goal({:print, p}), do: call(:print, [p])
  defp goal({:not, cond}), do: {:not, [], [Enum.map(cond, &goal/1)]}
  defp goal({:freeze, v, gs}), do: {:freeze, [], [pat(v), Enum.map(gs, &goal/1)]}
  defp goal({:gensym, v}), do: call(:gensym, [v])
  defp goal({:unify, a, b}), do: call(:unify, [a, b])
  defp goal({:equal, a, b}), do: {:==, [], [pat(a), pat(b)]}
  defp goal({:get_class, o, c}), do: call(:class, [o, c])
  defp goal({:get_super, o, s}), do: call(:super, [o, s])
  defp goal({:set_class, o, c}), do: call(:set_class, [o, c])
  defp goal({:set_super, o, s}), do: call(:set_super, [o, s])
  defp goal({:set_slots, o, s}), do: call(:set_slots, [o, s])
  defp goal({:get_slot, o, k, v}), do: call(:get_slot, [o, k, v])
  defp goal({:findall, t, cond, r}), do: {:findall, [], [pat(t), Enum.map(cond, &goal/1), pat(r)]}
  defp goal({:retract_class, o, c}), do: call(:retract_class, [o, c])
  defp goal({:retract_super, o, s}), do: call(:retract_super, [o, s])
  defp goal({:retract_slots, o, s}), do: call(:retract_slots, [o, s])
  defp goal({:get_method, o, n, i}), do: call(:method, [o, n, i])
  defp goal({:set_method, o, n, i}), do: call(:set_method, [o, n, i])
  defp goal({:send_async, o, m, a}), do: call(:send_async, [o, m, a])
  defp goal({:send_elixir, pid, msg}), do: call(:send_elixir, [pid, msg])
  defp goal({:retract_oapply, o, head}), do: call(:retract_oapply, [o, head])
  defp goal({:retract_method, o, n, i}), do: call(:retract_method, [o, n, i])
  defp goal({:get_oapply, o, _seq, h, b}), do: call(:clause, [o, h, b])
  defp goal({:set_oapply, o, _seq, h, b}), do: call(:set_oapply, [o, h, b])

  defp goal({:compare, op, a, b}), do: {op, [], [pat(a), pat(b)]}

  defp goal({:oapply, op, args}) when op in @arith, do: {op, [], Enum.map(args, &pat/1)}
  defp goal({:oapply, fun, args}), do: {fun, [], Enum.map(args, &pat/1)}

  defp goal({:forall, cond, body}),
    do: {:forall, [], [Enum.map(cond, &goal/1), Enum.map(body, &goal/1)]}

  defp goal({:or, left, right}),
    do: {:alternative, [], [Enum.map(left, &goal/1), Enum.map(right, &goal/1)]}

  defp goal({:implies, cond, then_, else_}) do
    cond_clause = {:->, [], [[Enum.map(cond, &goal/1)], goals(then_)]}
    else_clause = if else_ == [], do: [], else: [{:->, [], [[:else], goals(else_)]}]
    {:implies, [], [[do: [cond_clause | else_clause]]]}
  end

  defp goal({:call, head, body, args}),
    do:
      {:call, [],
       [pat(head), if(is_list(body), do: Enum.map(body, &goal/1), else: pat(body)), pat(args)]}

  defp goal({:call_next_method, self, args}), do: call(:call_next_method, [self, args])

  # A var in method position can't use the `method`, emit explicit send.
  defp goal({:send, r, m, args}) do
    if AL.Var.var?(m),
      do: {:send, [], [pat(r), pat(m), Enum.map(args, &pat/1)]},
      else: {m, [], [pat(r) | Enum.map(args, &pat/1)]}
  end

  defp goal(other), do: {:RAW, [], [Macro.escape(other)]}

  @spec call(atom(), [AL.Var.t()]) :: Macro.t()
  defp call(name, args), do: {name, [], Enum.map(args, &pat/1)}

  # Patterns inside a goal ---> AST ------------
  @spec pat(AL.Var.t()) :: Macro.t()
  defp pat(v) when is_atom(v) do
    s = Atom.to_string(v)

    if String.starts_with?(s, "$"),
      do: {s |> String.trim_leading("$") |> String.to_atom(), [], nil},
      else: v
  end

  defp pat([]), do: []
  defp pat([h | t]) when is_list(t), do: [pat(h) | pat(t)]
  defp pat([h | t]), do: [{:|, [], [pat(h), pat(t)]}]
  defp pat(m) when is_map(m), do: {:%{}, [], Enum.map(m, fn {k, v} -> {pat(k), pat(v)} end)}
  defp pat({:oapply, op, args}), do: {op, [], Enum.map(args, &pat/1)}
  defp pat({a, b}), do: {pat(a), pat(b)}
  defp pat(x), do: x
end
