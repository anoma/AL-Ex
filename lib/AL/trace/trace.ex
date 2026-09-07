defmodule AL.Trace do
  @moduledoc """
  I am the tracing module. I provide tracepoint functionality and readable
  rendering of AL terms.
  """

  @spec trace(atom()) :: :ok
  def trace(point) do
    Application.put_env(:al, :tracepoints, MapSet.put(tracepoints(), point))
  end

  @spec untrace(atom()) :: :ok
  def untrace(point) do
    Application.put_env(:al, :tracepoints, MapSet.delete(tracepoints(), point))
  end

  @spec notrace() :: :ok
  def notrace() do
    Application.put_env(:al, :tracepoints, MapSet.new())
  end

  @spec tracepoints() :: MapSet.t()
  def tracepoints() do
    Application.get_env(:al, :tracepoints, MapSet.new())
  end

  # Domino tracing model: two stacked Byrd boxes sharing an edge. `level` is `:method`
  # (dispatch's own provider/candidate search) or `:clause` (which clause of
  # the chosen provider runs) -- the same Call/Exit/Redo/Fail ports at both
  # levels, just printed with a prefix so a traced line always says which
  # box it's reporting on. These render exactly the port tuples already
  # appended to `state.domino.trace` (see `AL.begin_method_scope/5`,
  # `mark_exited/2`, `fail_scope/3` in `AL.ex`) -- no separate decision
  # logic, just formatting.
  @spec call(atom(), non_neg_integer(), term(), term(), [term()]) :: :ok
  def call(level, depth, receiver, method, args) do
    IO.puts([
      String.duplicate("  ", depth),
      level_label(level),
      "Call: ",
      inspect(pretty(receiver)),
      " <- ",
      inspect(pretty(method)),
      "(",
      args |> Enum.map(&inspect(pretty(&1))) |> Enum.join(", "),
      ")"
    ])
  end

  @spec exit(atom(), non_neg_integer(), term(), term()) :: :ok
  def exit(level, depth, receiver, method),
    do: port_line(level, depth, "Exit: ", receiver, method)

  @spec redo(atom(), non_neg_integer(), term(), term()) :: :ok
  def redo(level, depth, receiver, method),
    do: port_line(level, depth, "Redo: ", receiver, method)

  @spec fail(atom(), non_neg_integer(), term(), term()) :: :ok
  def fail(level, depth, receiver, method),
    do: port_line(level, depth, "Fail: ", receiver, method)

  defp port_line(level, depth, tag, receiver, method) do
    IO.puts([
      String.duplicate("  ", depth),
      level_label(level),
      tag,
      inspect(pretty(receiver)),
      " ",
      inspect(pretty(method))
    ])
  end

  defp level_label(:method), do: "Method "
  defp level_label(:clause), do: "Clause "

  # Post-hoc readable rendering of a completed run's `trace` -- domino
  # events always, a raw goal or `:backtrack`/`:flounder` interleaved in
  # only when the run opted in (`run vm_trace: true do ... end`). One
  # walk, one function: depth is reconstructed as it goes (Call opens a
  # level, Exit/Fail closes it back to its own Call's depth, Redo doesn't
  # change depth -- it's a sibling attempt, not a new level), and anything
  # that isn't a domino tuple (a raw goal, `:backtrack`, `:flounder`) just
  # prints inline at whatever depth the walk has reached so far -- no
  # cross-referencing needed, it's already sitting next to the Call that's
  # its context. `seen` remembers each open scope's receiver/method (only
  # Call carries that -- Exit/Redo/Fail are just a scope id) so those can
  # still print something meaningful instead of a bare scope number.
  # `steps` is chronological (already `Enum.reverse`d, e.g. `reason.trace`
  # from `format_failure/1`, or `state.domino.trace` on a success reversed
  # by the caller).
  @spec render([term()]) :: :ok
  def render(steps) do
    Enum.reduce(steps, {0, %{}}, &render_step/2)
    :ok
  end

  defp render_step({:method_call, scope, self, method, args, constraints_in}, {depth, seen}) do
    call(:method, depth, self, method, args)
    print_vars(depth, constraints_in)
    {depth + 1, Map.put(seen, scope, {self, method})}
  end

  defp render_step({:clause_call, scope, method_id, call_args, constraints_in}, {depth, seen}) do
    {receiver, args} =
      case call_args do
        [r | rest] -> {r, rest}
        other -> {other, []}
      end

    call(:clause, depth, receiver, method_id, args)
    print_vars(depth, constraints_in)
    {depth + 1, Map.put(seen, scope, {receiver, method_id})}
  end

  defp render_step({tag, scope, derived}, {depth, seen})
       when tag in [:method_exit, :clause_exit] do
    level = if tag == :method_exit, do: :method, else: :clause
    {receiver, method} = Map.get(seen, scope, {nil, nil})
    exit(level, depth - 1, receiver, method)
    print_vars(depth - 1, derived)
    {depth - 1, seen}
  end

  # Not a port: it annotates the box above it, so it prints at that box's own
  # depth and opens no level.
  defp render_step({:clause_chosen, scope, clause}, {depth, seen}) do
    {receiver, method} = Map.get(seen, scope, {nil, nil})
    port_line(:clause, depth - 1, "Chosen #{clause}: ", receiver, method)
    {depth, seen}
  end

  defp render_step({tag, scope}, {depth, seen}) when tag in [:method_redo, :clause_redo] do
    level = if tag == :method_redo, do: :method, else: :clause
    {receiver, method} = Map.get(seen, scope, {nil, nil})
    redo(level, depth - 1, receiver, method)
    {depth, seen}
  end

  defp render_step({tag, scope}, {depth, seen}) when tag in [:method_fail, :clause_fail] do
    level = if tag == :method_fail, do: :method, else: :clause
    {receiver, method} = Map.get(seen, scope, {nil, nil})
    fail(level, depth - 1, receiver, method)
    {depth - 1, seen}
  end

  defp render_step(entry, {depth, seen}) do
    IO.puts([String.duplicate("  ", depth), inspect(entry)])
    {depth, seen}
  end

  defp print_vars(_depth, descriptions) when map_size(descriptions) == 0, do: :ok

  defp print_vars(depth, descriptions) do
    IO.puts([String.duplicate("  ", depth + 1), inspect(descriptions)])
  end

  # Show the successful call in full. `store` resolves constraint leaves'
  # `derived`; without it they carry nil. A node's `clause` is the seq of
  # the clause that fired, read off the journal: nil on a constraint leaf
  # and on a method box whose clause box is its own node below.
  @spec derivation_tree([term()], AL.Var.store() | nil) :: [map()]
  def derivation_tree(steps, store \\ nil) do
    {_stack, nodes, _aliases, roots} =
      Enum.reduce(steps, {[], %{}, %{}, []}, &tree_step(&1, &2, store))

    roots
    |> Enum.reverse()
    |> Enum.reject(&Map.fetch!(nodes, &1).failed)
    |> Enum.map(&materialize(&1, nodes))
  end

  @doc """
  I collect every `method` call in a derivation tree (one or more roots, as
  returned by `derivation_tree/1`), resolving `self` and each arg through
  that node's own `derived`
  """
  @spec method_values(map() | [map()], atom()) :: [{term(), [term()]}]
  def method_values(roots, method) do
    roots
    |> List.wrap()
    |> Enum.flat_map(&method_nodes(&1, method))
    |> Enum.map(fn %{label: {self, ^method, args}, derived: derived} ->
      {resolve_derived(self, derived), Enum.map(args, &resolve_derived(&1, derived))}
    end)
    |> Enum.uniq()
  end

  defp method_nodes(%{label: {_, method, _}} = node, method),
    do: [node | Enum.flat_map(node.children, &method_nodes(&1, method))]

  defp method_nodes(node, method), do: Enum.flat_map(node.children, &method_nodes(&1, method))

  defp resolve_derived(term, derived) do
    case derived && Map.get(derived, term) do
      {:bound, val} -> val
      _ -> term
    end
  end

  defp tree_step({:method_call, scope, self, method, args, constraints_in}, acc, _store) do
    open_node(acc, scope, scope, %{
      kind: :method,
      label: {self, method, args},
      constraints_in: constraints_in,
      derived: nil,
      clause: nil,
      parent: nil,
      child_scopes: [],
      failed: false
    })
  end

  defp tree_step(
         {:clause_call, scope, method_id, call_args, constraints_in},
         {stack, nodes, aliases, roots} = acc,
         _store
       ) do
    collapse? =
      case stack do
        [top | _] -> match?(%{kind: :method, child_scopes: []}, Map.get(nodes, top))
        [] -> false
      end

    if collapse? do
      [top | _] = stack
      {[top | stack], nodes, Map.put(aliases, scope, top), roots}
    else
      open_node(acc, scope, scope, clause_node(method_id, call_args, constraints_in))
    end
  end

  defp tree_step({:clause_chosen, scope, clause}, {stack, nodes, aliases, roots}, _store) do
    resolved = Map.get(aliases, scope, scope)
    {stack, Map.update!(nodes, resolved, &%{&1 | clause: clause}), aliases, roots}
  end

  defp tree_step({tag, scope, derived}, {stack, nodes, aliases, roots}, _store)
       when tag in [:method_exit, :clause_exit] do
    resolved = Map.get(aliases, scope, scope)
    nodes = Map.update!(nodes, resolved, &%{&1 | derived: derived})
    {unwind(stack, resolved), nodes, aliases, roots}
  end

  defp tree_step({tag, scope}, {_stack, nodes, aliases, roots}, _store)
       when tag in [:method_redo, :clause_redo] do
    resolved = Map.get(aliases, scope, scope)
    nodes = Map.update!(nodes, resolved, &%{&1 | child_scopes: []})
    {ancestry(resolved, nodes), nodes, aliases, roots}
  end

  defp tree_step({tag, scope}, {stack, nodes, aliases, roots}, _store)
       when tag in [:method_fail, :clause_fail] do
    # A failed node is marked in place, not spliced out of its parent's
    # `child_scopes`/`roots` -- under heavy backtracking a node can pick up
    # many siblings, and removing one by value is O(siblings) each time.
    # `materialize/2` (the only reader, and a rare one relative to how often
    # a choicepoint fails) filters failed nodes out once instead.
    resolved = Map.get(aliases, scope, scope)
    nodes = Map.update!(nodes, resolved, &%{&1 | failed: true})

    {unwind(stack, resolved), nodes, aliases, roots}
  end

  defp tree_step(%AL.Goal.Compare{} = goal, acc, store),
    do: attach_constraint_leaf(goal, acc, store)

  defp tree_step(%AL.Goal.Dif{} = goal, acc, store), do: attach_constraint_leaf(goal, acc, store)

  defp tree_step(%AL.Goal.AllDif{} = goal, acc, store),
    do: attach_constraint_leaf(goal, acc, store)

  defp tree_step(%AL.Goal.InDomain{} = goal, acc, store),
    do: attach_constraint_leaf(goal, acc, store)

  # A raw goal (vm_trace was on, not one of the four constraint types above),
  # `:backtrack`, `:flounder` -- not part of the derivation tree at all, only
  # `render/1`'s job.
  defp tree_step(_other, acc, _store), do: acc

  defp ancestry(scope, nodes) do
    case Map.fetch!(nodes, scope).parent do
      nil -> [scope]
      parent -> [scope | ancestry(parent, nodes)]
    end
  end

  defp unwind(stack, scope) do
    if scope in stack do
      stack |> Enum.drop_while(&(&1 != scope)) |> Enum.drop_while(&(&1 == scope))
    else
      stack
    end
  end

  defp attach_constraint_leaf(goal, {stack, nodes, aliases, roots}, store) do
    key = make_ref()

    node = %{
      kind: :constraint,
      label: goal,
      constraints_in: %{},
      derived: constraint_derived(goal, store),
      clause: nil,
      parent: nil,
      child_scopes: [],
      failed: false
    }

    case stack do
      [] ->
        {stack, Map.put(nodes, key, node), aliases, [key | roots]}

      [parent | _] ->
        nodes =
          nodes
          |> Map.update!(parent, &%{&1 | child_scopes: [key | &1.child_scopes]})
          |> Map.put(key, %{node | parent: parent})

        {stack, nodes, aliases, roots}
    end
  end

  defp constraint_derived(_goal, nil), do: nil

  defp constraint_derived(goal, store),
    do: goal |> AL.Var.find_vars() |> Map.new(fn v -> {v, AL.describe_var(v, store)} end)

  # `push` is the resolved key to leave on `stack` for future children to
  # parent under (always the node's own resolved key -- see tree_step's
  # method_call/clause_call clauses for why this can differ from `scope`
  # itself in the collapse case).
  defp open_node({stack, nodes, aliases, roots}, scope, push, node) do
    case stack do
      [] ->
        {[push | stack], Map.put(nodes, scope, node), aliases, [scope | roots]}

      [parent | _] ->
        nodes =
          nodes
          |> Map.update!(parent, &%{&1 | child_scopes: [scope | &1.child_scopes]})
          |> Map.put(scope, %{node | parent: parent})

        {[push | stack], nodes, aliases, roots}
    end
  end

  defp clause_node(method_id, call_args, constraints_in) do
    {self, args} =
      case call_args do
        [r | rest] -> {r, rest}
        other -> {other, []}
      end

    %{
      kind: :clause,
      label: {self, method_id, args},
      constraints_in: constraints_in,
      derived: nil,
      clause: nil,
      parent: nil,
      child_scopes: [],
      failed: false
    }
  end

  defp materialize(scope, nodes) do
    node = Map.fetch!(nodes, scope)

    children =
      node.child_scopes
      |> Enum.reverse()
      |> Enum.reject(&Map.fetch!(nodes, &1).failed)
      |> Enum.map(&materialize(&1, nodes))

    %{
      kind: node.kind,
      label: node.label,
      constraints_in: node.constraints_in,
      derived: node.derived,
      clause: node.clause,
      children: children
    }
  end

  @spec render_tree([map()]) :: :ok
  def render_tree(roots) do
    count = length(roots)

    roots
    |> Enum.with_index(1)
    |> Enum.each(fn {node, idx} -> render_tree_node(node, "", idx == count) end)

    :ok
  end

  defp render_tree_node(%{kind: :constraint} = node, prefix, last?) do
    connector = if last?, do: "└─ ", else: "├─ "

    IO.puts([
      prefix,
      connector,
      "[constraint] ",
      inspect(pretty(node.label)),
      tree_derived_suffix(node.derived)
    ])

    render_tree_children(node, prefix, last?)
  end

  defp render_tree_node(node, prefix, last?) do
    connector = if last?, do: "└─ ", else: "├─ "
    {self, method, args} = node.label

    IO.puts([
      prefix,
      connector,
      tree_kind_label(node.kind),
      inspect(pretty(self)),
      " <- ",
      inspect(pretty(method)),
      "(",
      args |> Enum.map(&inspect(pretty(&1))) |> Enum.join(", "),
      ")",
      tree_derived_suffix(node.derived)
    ])

    render_tree_children(node, prefix, last?)
  end

  defp render_tree_children(node, prefix, last?) do
    child_prefix = prefix <> if last?, do: "   ", else: "│  "
    child_count = length(node.children)

    node.children
    |> Enum.with_index(1)
    |> Enum.each(fn {child, idx} -> render_tree_node(child, child_prefix, idx == child_count) end)
  end

  defp tree_kind_label(:clause), do: "[clause] "
  defp tree_kind_label(:method), do: ""

  defp tree_derived_suffix(nil), do: ""
  defp tree_derived_suffix(derived) when map_size(derived) == 0, do: ""
  defp tree_derived_suffix(derived), do: [" => ", inspect(pretty(derived))]

  # Method-level `call/4`/`fail/3` only fire once a clause is actually applied
  # — nothing says *which candidate legs an unbound receiver had to try* to
  # get there. This fires once, at `AL.Dispatch.dispatch/5`'s var-receiver
  # branch, before any leg has actually run. `durable` deliberately reports
  # as `deferred`, not a candidate count: durable candidate generation is
  # lazy (`AL.Dispatch.force_durable_candidates/4`) precisely so it doesn't
  # pay for a scan a cheaper leg might make unnecessary — reporting a count
  # here would force that scan just to trace it, undoing the laziness.
  @spec dispatch(term(), term(), [atom()]) :: :ok
  def dispatch(self, method, value_classes) do
    IO.puts([
      "Dispatch: ",
      inspect(pretty(self)),
      " <- ",
      inspect(pretty(method)),
      " (legs: value=",
      inspect(value_classes),
      ", durable=deferred)"
    ])
  end

  @spec pretty(term()) :: term()
  def pretty(a) when is_atom(a) do
    s = Atom.to_string(a)

    cond do
      hash?(s) -> :"##{AL.Command.id_label(AL.Branch.head(), a)}"
      AL.Var.var?(a) -> :"#{strip_freshener(s)}"
      true -> a
    end
  end

  def pretty(t) when is_tuple(t),
    do: t |> Tuple.to_list() |> Enum.map(&pretty/1) |> List.to_tuple()

  def pretty([]), do: []

  # Hand-written cons recursion rather than `Enum.map`, so an improper list with an
  # unbound-var tail (`[h | $tail]`, which AL forms freely) prettifies instead of
  # crashing the formatter on a non-`[]` tail.
  def pretty([h | t]), do: [pretty(h) | pretty(t)]

  def pretty(s) when is_struct(s),
    do: struct(s.__struct__, Map.new(Map.from_struct(s), fn {k, v} -> {k, pretty(v)} end))

  def pretty(m) when is_map(m),
    do: Map.new(m, fn {k, v} -> {pretty(k), pretty(v)} end)

  def pretty(x), do: x

  defp hash?(s) do
    byte_size(s) == 32 and Enum.all?(String.to_charlist(s), &(&1 in ?0..?9 or &1 in ?a..?f))
  end

  defp strip_freshener(s) do
    s
    |> String.split("_")
    |> Enum.reverse()
    |> Enum.drop_while(&integer_segment?/1)
    |> Enum.reverse()
    |> Enum.join("_")
  end

  defp integer_segment?(""), do: false
  defp integer_segment?(s), do: Enum.all?(String.to_charlist(s), &(&1 in ?0..?9))
end
