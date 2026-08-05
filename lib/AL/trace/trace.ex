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

  # `render/1` shows everything, including redo/fail churn -- good for "what
  # did the search actually try." This is the complementary view: only the
  # surviving derivation, as a real nested tree (not just indentation), one
  # node per logical send where possible. A method-box collapses into its
  # immediate clause-box when they're 1:1 (plain ground dispatch -- the
  # clause_call is the very next event after its method_call, nothing else
  # has happened yet); a method-box whose own resolution needs other sends
  # first (generative candidate construction, e.g. `:new`) shows those as
  # real, separate `:clause`-tagged children instead of being force-collapsed.
  #
  # Built flat (nodes keyed by scope, children referenced by scope id) and
  # materialized into real nesting in a final pass, since a parent's
  # children can't be mutated in place once created. `aliases` maps a
  # collapsed clause's own scope back to the method node it merged into, so
  # its own Exit/Fail still resolves to the right (shared) node. A Fail
  # splices its scope out of its parent's children outright, regardless of
  # what it built up across however many Redo attempts; a Redo resets a
  # node's children (that attempt is abandoned) but keeps the node itself,
  # to be repopulated by whatever runs next. `steps` is chronological, same
  # as `render/1` expects.
  @spec derivation_tree([term()]) :: [map()]
  def derivation_tree(steps) do
    {_stack, nodes, _aliases, roots} = Enum.reduce(steps, {[], %{}, %{}, []}, &tree_step/2)
    roots |> Enum.reverse() |> Enum.map(&materialize(&1, nodes))
  end

  @doc """
  I collect every `method` call in a derivation tree (one or more roots, as
  returned by `derivation_tree/1`), resolving `self` and each arg through
  that node's own `derived` -- a var that stayed a var (never in `derived`)
  is returned as-is, so a literal receiver/arg (already ground at call time)
  and a resolved one both come out the same way.
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

  # `stack` always holds *resolved* scope keys (post-alias), never a raw
  # collapsed clause scope -- `nodes` only has entries under resolved keys,
  # so a grandchild's parent lookup (`open_node`, via `hd(stack)`) would
  # miss entirely if a raw aliased scope were sitting on top instead. A
  # collapsed clause_call still needs to push *something*, since its own
  # later Exit/Fail has to pop a frame -- it pushes the resolved (method)
  # key again, which is safe: two pushes of the same resolved key exactly
  # match the two real events (clause_exit then method_exit) that will each
  # pop one off in turn. Pops themselves don't re-verify the popped value
  # against the firing event's own scope -- domino's Call/Exit nesting is
  # already guaranteed correct by construction (see AL.ex's begin_method_scope/
  # mark_exited/fail_scope), so this only ever needs to resolve-and-pop, not
  # cross-check.
  defp tree_step({:method_call, scope, self, method, args, constraints_in}, acc) do
    open_node(acc, scope, scope, %{
      kind: :method,
      label: {self, method, args},
      constraints_in: constraints_in,
      derived: nil,
      parent: nil,
      child_scopes: []
    })
  end

  defp tree_step(
         {:clause_call, scope, method_id, call_args, constraints_in},
         {stack, nodes, aliases, roots} = acc
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

  defp tree_step({tag, scope, derived}, {[_ | rest], nodes, aliases, roots})
       when tag in [:method_exit, :clause_exit] do
    resolved = Map.get(aliases, scope, scope)
    nodes = Map.update!(nodes, resolved, &%{&1 | derived: derived})
    {rest, nodes, aliases, roots}
  end

  # A redo resumes the box's interior choicepoint: the body does not
  # restart, so committed children stay -- the ones the resumption
  # abandons emit their own Fail and prune themselves.
  defp tree_step({tag, scope}, {stack, nodes, aliases, roots})
       when tag in [:method_redo, :clause_redo] do
    resolved = Map.get(aliases, scope, scope)
    {[resolved | stack], nodes, aliases, roots}
  end

  defp tree_step({tag, scope}, {[_ | rest], nodes, aliases, roots})
       when tag in [:method_fail, :clause_fail] do
    resolved = Map.get(aliases, scope, scope)
    node = Map.fetch!(nodes, resolved)

    {nodes, roots} =
      case node.parent do
        nil ->
          {nodes, List.delete(roots, resolved)}

        parent ->
          nodes =
            Map.update!(
              nodes,
              parent,
              &%{&1 | child_scopes: List.delete(&1.child_scopes, resolved)}
            )

          {nodes, roots}
      end

    {rest, nodes, aliases, roots}
  end

  # A raw goal, `:backtrack`, `:flounder` (vm_trace was on) -- not part of
  # the derivation tree at all, only `render/1`'s job.
  defp tree_step(_other, acc), do: acc

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
          |> Map.update!(parent, &%{&1 | child_scopes: &1.child_scopes ++ [scope]})
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
      parent: nil,
      child_scopes: []
    }
  end

  defp materialize(scope, nodes) do
    node = Map.fetch!(nodes, scope)

    %{
      kind: node.kind,
      label: node.label,
      constraints_in: node.constraints_in,
      derived: node.derived,
      children: Enum.map(node.child_scopes, &materialize(&1, nodes))
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
