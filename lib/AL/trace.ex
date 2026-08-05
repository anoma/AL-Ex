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
  def exit(level, depth, receiver, method), do: port_line(level, depth, "Exit: ", receiver, method)

  @spec redo(atom(), non_neg_integer(), term(), term()) :: :ok
  def redo(level, depth, receiver, method), do: port_line(level, depth, "Redo: ", receiver, method)

  @spec fail(atom(), non_neg_integer(), term(), term()) :: :ok
  def fail(level, depth, receiver, method), do: port_line(level, depth, "Fail: ", receiver, method)

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

  defp render_step({tag, scope, derived}, {depth, seen}) when tag in [:method_exit, :clause_exit] do
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
