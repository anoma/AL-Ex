defmodule AL.Trace do
  @moduledoc """
  I own an evaluation's composable trace flags and retained event stream, and
  provide tracepoint functionality and readable rendering of AL terms.

  Trace flags select independent detail levels:

    * `:domino` retains method/clause ports and constraint evidence
    * `:vm` retains every raw VM goal plus backtrack/flounder markers

  The legacy `trace_mode` option is normalized onto these flags by
  `flags_from_options!/1`.
  """

  use TypedStruct

  @type flag() :: :domino | :vm
  @type event() :: AL.Trace.Event.t()

  @allowed_flags MapSet.new([:domino, :vm])

  @derive {Inspect, only: [:flags, :events]}
  typedstruct enforce: true do
    field(:flags, MapSet.t(flag()), default: MapSet.new())
    field(:events, [event()], default: [])
    field(:runtime, AL.Trace.Runtime.t(), default: %AL.Trace.Runtime{})
  end

  @spec flags_from_options!(keyword()) :: MapSet.t(flag())
  def flags_from_options!(opts) do
    case {Keyword.fetch(opts, :trace), Keyword.fetch(opts, :trace_mode)} do
      {{:ok, _flags}, {:ok, _mode}} ->
        raise ArgumentError, "trace and trace_mode cannot be used together"

      {{:ok, flags}, :error} ->
        normalize_flags!(flags)

      {:error, {:ok, mode}} ->
        legacy_flags!(mode)

      {:error, :error} ->
        MapSet.new()
    end
  end

  @spec new(MapSet.t(flag())) :: t()
  def new(flags) do
    %__MODULE__{
      flags: flags,
      runtime: %AL.Trace.Runtime{tracepoints: tracepoints()}
    }
  end

  @spec enabled?(t(), flag()) :: boolean()
  def enabled?(%__MODULE__{flags: flags}, flag), do: MapSet.member?(flags, flag)

  @spec retained?(t()) :: boolean()
  def retained?(%__MODULE__{flags: flags}), do: MapSet.size(flags) > 0

  @spec push(t(), AL.Trace.Event.kind(), term()) :: t()
  def push(%__MODULE__{} = trace, kind, payload) do
    if enabled?(trace, kind),
      do: %__MODULE__{
        trace
        | events: [%AL.Trace.Event{kind: kind, payload: payload} | trace.events]
      },
      else: trace
  end

  @spec payload(event() | term()) :: term()
  def payload(%AL.Trace.Event{payload: payload}), do: payload
  def payload(other), do: other

  @spec payloads([event() | term()]) :: [term()]
  def payloads(events), do: Enum.map(events, &payload/1)

  defp normalize_flags!(%MapSet{} = flags), do: validate_flags!(flags)
  defp normalize_flags!(flags) when is_list(flags), do: flags |> MapSet.new() |> validate_flags!()

  defp normalize_flags!(other) do
    raise ArgumentError,
          "trace must be a list or MapSet of trace flags, got: #{inspect(other)}"
  end

  defp validate_flags!(flags) do
    unknown = MapSet.difference(flags, @allowed_flags)

    if MapSet.size(unknown) == 0 do
      flags
    else
      raise ArgumentError,
            "unknown trace flags #{inspect(MapSet.to_list(unknown))}; expected flags from #{inspect(MapSet.to_list(@allowed_flags))}"
    end
  end

  defp legacy_flags!(:no_trace), do: MapSet.new()
  defp legacy_flags!(:derivation_trace), do: MapSet.new([:domino])
  defp legacy_flags!(:full_trace), do: MapSet.new([:domino, :vm])

  defp legacy_flags!(mode) do
    raise ArgumentError,
          "trace_mode must be :no_trace, :derivation_trace, or :full_trace, got: #{inspect(mode)}"
  end

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
  # appended to `state.trace.events` (see `AL.begin_method_scope/5`,
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

  # Post-hoc readable rendering of an opted-in run's `trace` -- domino
  # events in derivation mode, with raw goals and `:backtrack`/`:flounder`
  # interleaved in `:full_trace` mode. One
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
  # from `format_failure/1`, or `state.trace.events` on a success reversed
  # by the caller).
  @spec render([term()]) :: :ok
  def render(steps) do
    Enum.reduce(steps, {0, %{}}, &render_step/2)
    :ok
  end

  defp render_step(%AL.Trace.Event{payload: payload}, acc), do: render_step(payload, acc)

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

  defp render_step({:constraint, goal, constraints_in, derived}, {depth, seen}) do
    IO.puts([String.duplicate("  ", depth), "Constraint: ", inspect(pretty(goal))])
    print_constraint_transition(depth, constraints_in, derived)
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

  defp render_step({:collection_begin, _scope, kind, _condition, _output}, {depth, seen}) do
    IO.puts([String.duplicate("  ", depth), "Collection: ", Atom.to_string(kind)])
    {depth, seen}
  end

  defp render_step({:collection_solution, _scope, _store}, {depth, seen}) do
    IO.puts([String.duplicate("  ", depth), "Collection Solution"])
    {depth, seen}
  end

  defp render_step({:collection_end, _scope}, acc), do: acc

  defp render_step(entry, {depth, seen}) do
    IO.puts([String.duplicate("  ", depth), inspect(entry)])
    {depth, seen}
  end

  defp print_vars(_depth, descriptions) when map_size(descriptions) == 0, do: :ok

  defp print_vars(depth, descriptions) do
    IO.puts([String.duplicate("  ", depth + 1), inspect(descriptions)])
  end

  @doc """
  I build the successful derivation tree from a completed AL evaluation state.
  I obtain its retained journal and final variable store directly.
  """
  @spec derivation_tree(AL.t()) :: [map()]
  def derivation_tree(state), do: AL.Trace.Derivation.build(state)

  @doc """
  I collect every `method` call in a derivation tree (one or more roots, as
  returned by `derivation_tree/1`), resolving `self` and each arg through
  each successful answer's `derived`
  """
  @spec method_values(map() | [map()], atom()) :: [{term(), [term()]}]
  def method_values(roots, method), do: AL.Trace.Derivation.method_values(roots, method)

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
      inspect(pretty(node.label))
    ])

    transition_prefix = prefix <> if last?, do: "   ", else: "│  "
    print_constraint_transition(transition_prefix, node.constraints_in, node.derived)

    render_tree_children(node, prefix, last?)
  end

  defp render_tree_node(%{kind: :answer} = node, prefix, last?) do
    connector = if last?, do: "└─ ", else: "├─ "
    clause = if is_nil(node.clause), do: "", else: " clause #{node.clause}"

    IO.puts([
      prefix,
      connector,
      "[answer",
      clause,
      "]",
      tree_derived_suffix(node.derived)
    ])

    render_tree_children(node, prefix, last?)
  end

  defp render_tree_node(%{kind: :collection, label: {kind, _condition}} = node, prefix, last?) do
    connector = if last?, do: "└─ ", else: "├─ "
    IO.puts([prefix, connector, "[", Atom.to_string(kind), "]"])
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
      ")"
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

  defp print_constraint_transition(_depth, constraints_in, derived)
       when constraints_in == derived,
       do: :ok

  defp print_constraint_transition(depth, constraints_in, derived) when is_integer(depth) do
    print_constraint_transition(String.duplicate("  ", depth + 1), constraints_in, derived)
  end

  defp print_constraint_transition(prefix, constraints_in, derived) do
    IO.puts([prefix, "in:  ", inspect(pretty(constraints_in))])
    IO.puts([prefix, "out: ", inspect(pretty(derived))])
  end

  @spec dispatch(term(), term(), [atom()]) :: :ok
  def dispatch(self, method, providers) do
    IO.puts([
      "Dispatch: ",
      inspect(pretty(self)),
      " <- ",
      inspect(pretty(method)),
      " (providers=",
      inspect(providers),
      ")"
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

  def pretty({:"$fresh", base, _scope}), do: pretty(base)

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
