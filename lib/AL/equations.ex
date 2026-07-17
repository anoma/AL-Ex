defmodule AL.Equations do
  @moduledoc """
  I compile an equation over prefix terms into DSL goals: each
  solvable direction isolated and frozen on its inputs, no direction
  a frozen check. I am `AL.Package.Equations` inlined at translate
  time, for clients that know their terms before they run.

      AL.Equations.equation([:add, :a, 1], :b, "e0")
      AL.Equations.equation([:mul, :a, 2], :b, "e1", feed: [:a])

  Leaves are integers or atoms; an atom names a DSL variable. A
  `feed:` name is never solved for, only waited on; a `free:` name is
  taken as given, neither solved for nor waited on.
  """

  @inverse %{add: :-, mul: :/}

  @doc "I emit every direction of `t = u`, tagged so my fresh names stay apart."
  @spec equation(term(), term(), String.t(), keyword()) :: [Macro.t()]
  def equation(t, u, tag, opts \\ []) do
    feed = Keyword.get(opts, :feed, [])
    free = Keyword.get(opts, :free, [])
    names = (leaves(t) ++ leaves(u)) |> Enum.reject(&(&1 in free)) |> Enum.frequencies()
    targets = for {name, 1} <- names, name not in feed, do: name

    case targets do
      [] ->
        frozen(Map.keys(names), check(:"#{tag}chk", pure(t), pure(u)))

      targets ->
        Enum.flat_map(targets, fn target ->
          inputs = for {name, _n} <- names, name != target, do: name
          frozen(inputs, isolate(target, t, u, "#{tag}#{target}"))
        end)
    end
  end

  @doc "I nest goals under one freeze per name, outermost last."
  @spec frozen([atom()], [Macro.t()]) :: [Macro.t()]
  def frozen(names, goals) do
    names
    |> Enum.uniq()
    |> Enum.reduce(goals, fn name, acc -> [{:freeze, [], [v(name), acc]}] end)
  end

  @doc "I state `a = b` through a shared fresh variable named `name`."
  @spec check(atom(), Macro.t(), Macro.t()) :: [Macro.t()]
  def check(name, a, b),
    do: [
      quote(do: vm_is(unquote(v(name)), unquote(a))),
      quote(do: vm_is(unquote(v(name)), unquote(b)))
    ]

  defp isolate(target, t, u, tag) do
    if target in leaves(t),
      do: descend(target, t, pure(u), tag),
      else: descend(target, u, pure(t), tag)
  end

  # Algebra walks down to the target: addition subtracts away, and
  # multiplication divides exactly or fails the clause.
  defp descend(target, [op, a, b], acc, tag) when is_map_key(@inverse, op) do
    {into, other} = if target in leaves(a), do: {a, b}, else: {b, a}
    inverted = {@inverse[op], [], [acc, pure(other)]}

    exact =
      if op == :mul,
        do: check(:"#{tag}rem", quote(do: rem(unquote(acc), unquote(pure(other)))), 0),
        else: []

    exact ++ descend(target, into, inverted, tag)
  end

  defp descend(target, _leaf, acc, _tag), do: [quote(do: vm_is(unquote(v(target)), unquote(acc)))]

  defp leaves(n) when is_integer(n), do: []
  defp leaves(a) when is_atom(a), do: [a]
  defp leaves([op, t, u]) when op in [:add, :mul], do: leaves(t) ++ leaves(u)

  defp pure(n) when is_integer(n), do: n
  defp pure(a) when is_atom(a), do: v(a)
  defp pure([:add, t, u]), do: {:+, [], [pure(t), pure(u)]}
  defp pure([:mul, t, u]), do: {:*, [], [pure(t), pure(u)]}

  defp v(name), do: {name, [], nil}
end
