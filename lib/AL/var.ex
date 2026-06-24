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

  @spec to_mnesia_pattern(t()) :: t()
  @spec to_mnesia_pattern(t(), pos_integer()) :: {t(), pos_integer()}
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
  # the bindings so `subst`/`deref` can't loop forever.
  @spec bind(bindings(), variable(), t()) :: bindings() | nil
  defp bind(bindings, var, term) do
    if occurs?(var, term, bindings), do: nil, else: Map.put(bindings, var, term)
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
  def subst(x, bindings) when is_atom(x) do
    rx = deref(bindings, x)

    if rx == x do
      x
    else
      subst(rx, bindings)
    end
  end

  def subst([], _bindings), do: []

  def subst([x | xs], bindings) do
    [subst(x, bindings) | subst(xs, bindings)]
  end

  def subst(m, bindings) when is_map(m) do
    Map.new(m, fn {k, v} -> {subst(k, bindings), subst(v, bindings)} end)
  end

  def subst(xs, bindings) when is_tuple(xs) do
    xs
    |> Tuple.to_list()
    |> subst(bindings)
    |> List.to_tuple()
  end

  def subst(x, _), do: x

  @spec find_vars(t()) :: MapSet.t(variable())
  @spec find_vars(t(), MapSet.t(variable())) :: MapSet.t(variable())
  def find_vars(d) do
    find_vars(d, MapSet.new([]))
  end

  def find_vars(v, s) when is_atom(v) do
    if var?(v) do
      MapSet.put(s, v)
    else
      s
    end
  end

  def find_vars([], s), do: s

  def find_vars([x | xs], s) do
    find_vars(xs, find_vars(x, s))
  end

  def find_vars(m, s) when is_map(m) do
    Enum.reduce(m, s, fn {k, v}, acc ->
      find_vars(v, find_vars(k, acc))
    end)
  end

  def find_vars(xs, s) when is_tuple(xs) do
    xs
    |> Tuple.to_list()
    |> find_vars(s)
  end

  def find_vars(_, s), do: s

  @spec freshen(t(), String.t()) :: t()
  def freshen(v, f) when is_atom(v) do
    if var?(v) && v != :"$_" do
      var(name(v) <> "_" <> f)
    else
      v
    end
  end

  def freshen([], _f), do: []

  def freshen([x | xs], f) do
    [freshen(x, f) | freshen(xs, f)]
  end

  def freshen(m, f) when is_map(m) do
    Map.new(m, fn {k, v} -> {freshen(k, f), freshen(v, f)} end)
  end

  def freshen(xs, f) when is_tuple(xs) do
    xs
    |> Tuple.to_list()
    |> freshen(f)
    |> List.to_tuple()
  end

  def freshen(v, _f), do: v
end
