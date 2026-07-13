defmodule AL.Var do
  @moduledoc """
  I provide symbolic utilities for AL.

  Some terminology:

  Bindings is a forest of variable references where the leaves are ground terms and act as roots of the reference chain

  Vars look like :"$<string>"
  """

  @type variable() :: atom()
  @type t() :: atom() | number() | binary() | [t()] | tuple() | map()
  @type bindings() :: %{optional(variable()) => t()}

  @spec empty_bindings() :: bindings()
  def empty_bindings() do
    %{}
  end

  @spec var?(term()) :: boolean()
  def var?(x) when is_atom(x) do
    x
    |> Atom.to_string()
    |> String.starts_with?("$")
  end

  def var?(_x) do
    false
  end

  @spec var(String.t() | atom()) :: variable()
  def var(x) do
    :"$#{x}"
  end

  @spec name(variable()) :: String.t()
  def name(x) do
    "$" <> name = Atom.to_string(x)
    name
  end

  @typep mnesia_acc() :: {pos_integer(), %{optional(variable()) => pos_integer()}}

  @spec to_mnesia_pattern(t()) :: t()
  @spec to_mnesia_pattern(t(), mnesia_acc()) :: {t(), mnesia_acc()}
  def to_mnesia_pattern(p) do
    {p, _acc} = to_mnesia_pattern(p, {1, %{}})
    p
  end

  def to_mnesia_pattern(v, {n, seen}) when is_atom(v) do
    if var?(v) do
      case Map.get(seen, v) do
        nil -> {:"$#{n}", {n + 1, Map.put(seen, v, n)}}
        existing -> {:"$#{existing}", {n, seen}}
      end
    else
      {v, {n, seen}}
    end
  end

  def to_mnesia_pattern([], acc), do: {[], acc}

  def to_mnesia_pattern([x | xs], acc) do
    {x1, acc1} = to_mnesia_pattern(x, acc)
    {xs1, acc_final} = to_mnesia_pattern(xs, acc1)

    {[x1 | xs1], acc_final}
  end

  def to_mnesia_pattern(xs, acc) when is_tuple(xs) do
    {xs, acc} =
      xs
      |> Tuple.to_list()
      |> to_mnesia_pattern(acc)

    {List.to_tuple(xs), acc}
  end

  def to_mnesia_pattern(m, acc) when is_map(m) do
    {kvs, acc2} =
      Enum.map_reduce(m, acc, fn {k, v}, a ->
        {v2, a2} = to_mnesia_pattern(v, a)
        {{k, v2}, a2}
      end)

    {Map.new(kvs), acc2}
  end

  def to_mnesia_pattern(x, acc), do: {x, acc}

  @spec deref(bindings(), variable()) :: t()
  def deref(bindings, k) do
    case Map.get(bindings, k) do
      nil ->
        k

      ^k ->
        k

      v ->
        if var?(v) do
          deref(bindings, v)
        else
          v
        end
    end
  end

  @spec extend(bindings(), t(), t()) :: bindings() | nil
  def extend(bindings, x, y) do
    rx = deref(bindings, x)
    ry = deref(bindings, y)

    is_var_rx = var?(rx)
    is_var_ry = var?(ry)

    cond do
      rx == ry -> bindings
      not is_var_rx && is_var_ry -> bind(bindings, ry, x)
      rx == x && is_var_ry -> bind(bindings, ry, x)
      not is_var_ry && is_var_rx -> bind(bindings, rx, y)
      ry == y && is_var_rx -> bind(bindings, rx, y)
      is_var_ry && is_var_rx -> bind(bindings, rx, ry)
      true -> unify(rx, ry, bindings)
    end
  end

  # Bind `var` to `term`, refusing (returning nil, i.e. unification failure) if
  # `var` occurs in `term` — the occurs check, which keeps cyclic terms out of
  # the bindings so `subst`/`deref` can't loop forever — or if the binding would
  # satisfy a `dif/2` parked on `var` (see `add_dif/3`).
  @spec bind(bindings(), variable(), t()) :: bindings() | nil
  defp bind(bindings, var, term) do
    if occurs?(var, term, bindings) do
      nil
    else
      new_bindings =
        bindings
        |> Map.put(var, term)
        |> migrate_dif(var, term)

      if dif_violated?(new_bindings, var), do: nil, else: new_bindings
    end
  end

  # `extend/3` picks which of two still-open vars becomes the alias and which
  # stays live by argument position, not by which one carries a `dif`
  # constraint — so a constrained var can end up retired in favour of a fresh
  # one that has never heard of the constraint. Carry it forward onto
  # whichever var is still live, or a later bind of the survivor alone would
  # never see it.
  defp migrate_dif(bindings, var, term) do
    if var?(term) do
      case Map.get(bindings, {:dif, var}) do
        nil -> bindings
        pairs -> Map.update(bindings, {:dif, term}, pairs, &(pairs ++ &1))
      end
    else
      bindings
    end
  end

  # `dif/2` constraints live as extra entries in the same `bindings` map, keyed
  # by `{:dif, var}` for every var either side mentions — a tuple key, so it
  # can never collide with an actual var (vars are always `$`-prefixed atoms,
  # see `var?/1`) and is invisible to `deref`/`subst`'s normal atom-keyed
  # lookups. That means it needs no dedicated field on `AL.Choicepoint`: it
  # rides along on every backtrack for free, the same way an ordinary binding
  # does, since a choicepoint already carries its own full snapshot of
  # `bindings` rather than a WAM-style trail.
  @spec add_dif(bindings(), t(), t()) :: bindings()
  def add_dif(bindings, a, b) do
    a
    |> find_vars(find_vars(b))
    |> Enum.reduce(bindings, fn v, acc ->
      Map.update(acc, {:dif, v}, [{a, b}], &[{a, b} | &1])
    end)
  end

  @spec dif_violated?(bindings(), variable()) :: boolean()
  defp dif_violated?(bindings, var) do
    bindings
    |> Map.get({:dif, var}, [])
    |> Enum.any?(fn {a, b} -> subst(a, bindings) == subst(b, bindings) end)
  end

  @spec occurs?(variable(), t(), bindings()) :: boolean()
  def occurs?(var, term, bindings) do
    term = if is_atom(term), do: deref(bindings, term), else: term

    cond do
      var?(term) -> term == var
      # handle cons cells directly so improper lists (`[h | $tail]`) work
      is_list(term) -> occurs_in_list?(var, term, bindings)
      is_tuple(term) -> occurs_in_list?(var, Tuple.to_list(term), bindings)
      is_map(term) -> occurs_in_list?(var, Map.values(term), bindings)
      true -> false
    end
  end

  defp occurs_in_list?(var, [head | tail], bindings),
    do: occurs?(var, head, bindings) or occurs_in_list?(var, tail, bindings)

  defp occurs_in_list?(_var, [], _bindings), do: false

  defp occurs_in_list?(var, tail, bindings), do: occurs?(var, tail, bindings)

  @spec unify(t(), t(), bindings()) :: bindings() | nil
  def unify(x, y, bindings \\ %{}) do
    cond do
      x == :"$_" || y == :"$_" ->
        bindings

      var?(x) || var?(y) ->
        extend(bindings, x, y)

      is_list(x) && is_list(y) && x != [] && y != [] ->
        [x | xs] = x
        [y | ys] = y

        case unify(x, y, bindings) do
          nil -> nil
          next_bindings -> unify(xs, ys, next_bindings)
        end

      is_tuple(x) && is_tuple(y) && tuple_size(x) == tuple_size(y) ->
        unify(Tuple.to_list(x), Tuple.to_list(y), bindings)

      is_map(x) && is_map(y) ->
        keys = Map.keys(x) |> MapSet.new() |> MapSet.intersection(MapSet.new(Map.keys(y)))

        unify(
          Enum.map(keys, fn k -> Map.get(x, k) end),
          Enum.map(keys, fn k -> Map.get(y, k) end),
          bindings
        )

      x == y ->
        bindings

      true ->
        nil
    end
  end

  @spec subst(t(), bindings()) :: t()
  def subst(term, bindings), do: subst(term, bindings, & &1)

  # `rewrite_unbound` lets a caller rename a var that's still unbound after
  # dereferencing (e.g. AL.eval's display layer, which maps an internal freshened
  # var back to whichever observable query var it's aliased to) instead of
  # showing it as-is.
  @spec subst(t(), bindings(), (variable() -> t())) :: t()
  def subst(term, bindings, rewrite_unbound),
    do: AL.Goal.map(term, &subst_leaf(&1, bindings, rewrite_unbound))

  # A bound var derefs to its term, which is itself substituted
  defp subst_leaf(leaf, bindings, rewrite_unbound) when is_atom(leaf) do
    case deref(bindings, leaf) do
      ^leaf ->
        if var?(leaf), do: rewrite_unbound.(leaf), else: leaf

      other ->
        if var?(other), do: rewrite_unbound.(other), else: subst(other, bindings, rewrite_unbound)
    end
  end

  defp subst_leaf(leaf, _bindings, _rewrite_unbound), do: leaf

  @spec find_vars(t()) :: MapSet.t(variable())
  @spec find_vars(t(), MapSet.t(variable())) :: MapSet.t(variable())
  def find_vars(term), do: find_vars(term, MapSet.new())

  def find_vars(term, acc) do
    AL.Goal.reduce(term, acc, fn leaf, s -> if var?(leaf), do: MapSet.put(s, leaf), else: s end)
  end

  @spec freshen(t(), String.t()) :: t()
  def freshen(term, f) do
    AL.Goal.map(term, fn leaf ->
      if var?(leaf) and leaf != :"$_", do: var(name(leaf) <> "_" <> f), else: leaf
    end)
  end
end
