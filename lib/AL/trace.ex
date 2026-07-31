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

  @spec call(non_neg_integer(), term(), term(), [term()]) :: :ok
  def call(depth, receiver, method, args) do
    IO.puts([
      String.duplicate("  ", depth),
      "Call: ",
      inspect(pretty(receiver)),
      " <- ",
      inspect(pretty(method)),
      "(",
      args |> Enum.map(&inspect(pretty(&1))) |> Enum.join(", "),
      ")"
    ])
  end

  @spec fail(non_neg_integer(), term(), term()) :: :ok
  def fail(depth, receiver, method) do
    IO.puts([
      String.duplicate("  ", depth),
      "Fail: ",
      inspect(pretty(receiver)),
      " ",
      inspect(pretty(method))
    ])
  end

  # Method-level `call/4`/`fail/3` only fire once a clause is actually applied
  # — nothing says *which candidate legs an unbound receiver had to try* to
  # get there. This fires once, at `AL.Dispatch.dispatch/5`'s var-receiver
  # branch, before any leg has actually run. `durable` deliberately reports
  # as `deferred`, not a candidate count: durable candidate generation is
  # lazy (`AL.Dispatch.force_durable_candidates/4`) precisely so it doesn't
  # pay for a scan a cheaper leg might make unnecessary — reporting a count
  # here would force that scan just to trace it, undoing the laziness.
  @spec dispatch(term(), term(), [atom()], [atom()]) :: :ok
  def dispatch(self, method, ephemeral_classes, value_classes) do
    IO.puts([
      "Dispatch: ",
      inspect(pretty(self)),
      " <- ",
      inspect(pretty(method)),
      " (legs: structural=[cons, []], ephemeral=",
      inspect(ephemeral_classes),
      ", value=",
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
