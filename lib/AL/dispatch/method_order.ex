defmodule AL.Dispatch.MethodOrder do
  @moduledoc """
  I compute a receiver's method resolution order — which classes/supers get
  searched, and in what order — as an ordinary topological sort (Kahn's
  algorithm) over the `super` relation. Pure functions of a receiver/class and
  a branch; no choicepoint or bindings involved.
  """

  # Ordered lookup scopes: the receiver (if an atom), then its classes and their
  # supers, depth-first (or breadth-first, if the receiver's class opts in via a
  # `dispatch_strategy: :bfs` slot) and deduped. Map/list/number receivers start
  # from `:map`/`:list`/`:number` and always walk depth-first.
  def method_scopes(self, branch) when is_map(self),
    do: super_chain([Map.get(self, :class, :map)], branch, :dfs)

  def method_scopes(self, branch) when is_list(self), do: super_chain([:list], branch, :dfs)

  def method_scopes(self, branch) when is_number(self), do: super_chain([:number], branch, :dfs)

  def method_scopes(self, branch) do
    classes = for({:class, _o, _seq, c} <- AL.Object.scan_class(self, :"$class", branch), do: c)
    chain = super_chain(classes, branch, dispatch_strategy(classes, branch))

    if Enum.any?(classes, &(&1 in [:class, :category, :behaviour])) do
      chain
    else
      [self | chain]
    end
  end

  def super_chain(seeds, branch, strategy) do
    edges = collect_edges(seeds, branch, MapSet.new(), %{})
    in_degree = in_degrees(edges)

    ready = Enum.filter(seeds, &(Map.get(in_degree, &1, 0) == 0))

    kahn(ready, edges, in_degree, strategy, [])
  end

  # The reverse of super_chain/3: that walks UP from an instance/class to
  # its ancestors, this walks DOWN from an ancestor to every class that has
  # it somewhere in *its own* super chain. Includes `class` itself. Needed
  # wherever an isa constraint (transitive by definition -- a durable
  # object classed :dog still satisfies isa: [:animal]) has to become a
  # concrete set of classes to search, rather than a single equality check.
  # No ordering guarantee (unlike super_chain, nothing consumes this as a
  # resolution order) and no dispatch_strategy involved -- this is a plain
  # membership/enumeration question, not a try-order one.
  @spec descendants_of(atom(), AL.Branch.t()) :: [atom()]
  def descendants_of(class, branch), do: descendants_of([class], branch, MapSet.new())

  defp descendants_of([], _branch, seen), do: MapSet.to_list(seen)

  defp descendants_of([class | rest], branch, seen) do
    if MapSet.member?(seen, class) do
      descendants_of(rest, branch, seen)
    else
      children =
        for {:super, child, _seq, ^class} <-
              AL.Object.scan_super(
                AL.Var.var("descendant_scan_#{AL.fresh_scope()}"),
                class,
                branch
              ),
            do: child

      descendants_of(children ++ rest, branch, MapSet.put(seen, class))
    end
  end

  # The strategy is decided once, from the receiver's own immediate classes — a
  # direct slot read, never a search up the hierarchy — and then applied to the
  # whole traversal below. Defaults to `:dfs` if unset or there's no class.
  defp dispatch_strategy([], _branch), do: :dfs

  defp dispatch_strategy([class | _rest], branch) do
    case AL.Object.read_slots(class, branch) do
      [{:slots, ^class, %{dispatch_strategy: strategy}}] -> strategy
      _ -> :dfs
    end
  end

  # Walks every class reachable from `seeds`, recording each one's direct
  # supers. Just edge collection — the ordering happens in `kahn/5` below.
  defp collect_edges([], _branch, _seen, edges), do: edges

  defp collect_edges([class | rest], branch, seen, edges) do
    if MapSet.member?(seen, class) do
      collect_edges(rest, branch, seen, edges)
    else
      supers = for {:super, _o, _seq, s} <- AL.Object.scan_super(class, :"$super", branch), do: s

      collect_edges(
        supers ++ rest,
        branch,
        MapSet.put(seen, class),
        Map.put(edges, class, supers)
      )
    end
  end

  # A class's in-degree is how many other reachable classes name it as a
  # super — how many subclasses still need to be placed before it's eligible.
  defp in_degrees(edges) do
    base = Map.new(edges, fn {class, _supers} -> {class, 0} end)

    Enum.reduce(edges, base, fn {_class, supers}, acc ->
      Enum.reduce(supers, acc, fn s, acc2 -> Map.update(acc2, s, 1, &(&1 + 1)) end)
    end)
  end

  # Kahn's algorithm: a class only becomes eligible once every reachable
  # subclass of it has already been placed, so a shared ancestor (`object`,
  # or any common mixin base) always sinks to the end of the chain instead of
  # landing wherever traversal happens to first reach it. `strategy` only
  # breaks ties among classes that become eligible at the same time — it
  # never overrides the forced "subclass before super" ordering.
  defp kahn([], _edges, _in_degree, _strategy, acc), do: Enum.reverse(acc)

  defp kahn([class | rest], edges, in_degree, strategy, acc) do
    supers = Map.get(edges, class, [])

    {newly_ready, in_degree} =
      Enum.reduce(supers, {[], in_degree}, fn s, {ready, deg} ->
        deg = Map.update!(deg, s, &(&1 - 1))
        if deg[s] == 0, do: {ready ++ [s], deg}, else: {ready, deg}
      end)

    queue =
      case strategy do
        :bfs -> rest ++ newly_ready
        :dfs -> newly_ready ++ rest
      end

    kahn(queue, edges, in_degree, strategy, [class | acc])
  end
end
