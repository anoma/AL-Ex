defmodule AL.Var do
  @moduledoc """
  I provide symbolic utilities for AL.

  Some terminology:

  Bindings is a forest of variable references where the leaves are ground terms and act as roots of the reference chain

  Vars look like :"$<string>"; a freshened var wraps its original as
  {:"$fresh", base, scope}, so resolution mints no atoms.
  """

  @type variable() :: atom() | {:"$fresh", variable(), String.t()}
  @type t() :: atom() | number() | binary() | [t()] | tuple() | map()
  @type bindings() :: %{optional(variable()) => t()}
  @type constraint_set() :: %{dif: [{t(), t()}], isa: MapSet.t(atom())}
  @type constraints() :: %{optional(variable()) => constraint_set()}

  @spec empty_bindings() :: bindings()
  def empty_bindings() do
    %{}
  end

  @spec var?(term()) :: boolean()
  def var?({:"$fresh", _base, _scope}), do: true

  def var?(x) when is_atom(x) do
    case Atom.to_string(x) do
      <<"$", _::binary>> -> true
      _ -> false
    end
  end

  def var?(_x) do
    false
  end

  @spec var(String.t() | atom()) :: variable()
  def var(x) do
    :"$#{x}"
  end

  @spec name(variable()) :: String.t()
  def name({:"$fresh", base, scope}), do: name(base) <> "_" <> scope

  def name(x) do
    "$" <> name = Atom.to_string(x)
    name
  end

  @spec fresh(variable(), String.t()) :: variable()
  def fresh(base, scope), do: {:"$fresh", base, scope}

  @typep mnesia_acc() :: {pos_integer(), %{optional(variable()) => pos_integer()}}

  @spec to_mnesia_pattern(t()) :: t()
  @spec to_mnesia_pattern(t(), mnesia_acc()) :: {t(), mnesia_acc()}
  def to_mnesia_pattern(p) do
    {p, _acc} = to_mnesia_pattern(p, {1, %{}})
    p
  end

  def to_mnesia_pattern({:"$fresh", _base, _scope} = v, {n, seen}) do
    case Map.get(seen, v) do
      nil -> {:"$#{n}", {n + 1, Map.put(seen, v, n)}}
      existing -> {:"$#{existing}", {n, seen}}
    end
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

  @spec extend(bindings(), t(), t(), constraints(), AL.Branch.t()) ::
          {bindings(), constraints()} | nil
  def extend(bindings, x, y, constraints, branch) do
    rx = deref(bindings, x)
    ry = deref(bindings, y)

    is_var_rx = var?(rx)
    is_var_ry = var?(ry)

    cond do
      rx == ry -> {bindings, constraints}
      not is_var_rx && is_var_ry -> bind(bindings, ry, x, constraints, branch)
      rx == x && is_var_ry -> bind(bindings, ry, x, constraints, branch)
      not is_var_ry && is_var_rx -> bind(bindings, rx, y, constraints, branch)
      ry == y && is_var_rx -> bind(bindings, rx, y, constraints, branch)
      is_var_ry && is_var_rx -> bind(bindings, rx, ry, constraints, branch)
      true -> unify(rx, ry, bindings, constraints, branch)
    end
  end

  # Bind `var` to `term`, refusing (returning nil, i.e. unification failure) if
  # `var` occurs in `term` — the occurs check, which keeps cyclic terms out of
  # the bindings so `subst`/`deref` can't loop forever — or if the binding would
  # satisfy a `dif/2` or `isa` parked on `var` (see `add_dif/3`/`add_isa/3`).
  # This is the one choke point every unification in the VM passes through
  # (`extend/5` is `bind/5`'s only caller, `unify/5` is `extend/5`'s only
  # caller — dispatch's own candidate generation included, since
  # `AL.Dispatch.structural_candidate` unifies through this same path), so
  # it's the only place a constraint check is guaranteed to see every bind
  # regardless of how deep in the interpreter it happens. `branch` only
  # matters for `isa`: verifying a durable class needs a lookup of the
  # concrete term's own class row (`AL.Dispatch.MethodOrder.method_scopes/2`)
  # — cheap (one object's own classification), not the scan generating
  # durable *candidates* needs (see al-dif-constraints memory).
  @spec bind(bindings(), variable(), t(), constraints(), AL.Branch.t()) ::
          {bindings(), constraints()} | nil
  defp bind(bindings, var, term, constraints, branch) do
    if occurs?(var, term, bindings) do
      nil
    else
      new_bindings = Map.put(bindings, var, term)
      new_constraints = migrate_constraints(constraints, var, term)

      if constraints_violated?(new_constraints, new_bindings, var, term, branch) do
        nil
      else
        {new_bindings, new_constraints}
      end
    end
  end

  # `extend/4` picks which of two still-open vars becomes the alias and which
  # stays live by argument position, not by which one carries a constraint —
  # so a constrained var can end up retired in favour of a fresh one that has
  # never heard of it. Carry its constraints forward onto whichever var is
  # still live, or a later bind of the survivor alone would never see them.
  defp migrate_constraints(constraints, var, term) do
    if var?(term) do
      case Map.get(constraints, var) do
        nil -> constraints
        set -> Map.update(constraints, term, set, &merge_constraint_sets(&1, set))
      end
    else
      constraints
    end
  end

  defp merge_constraint_sets(a, b), do: %{dif: a.dif ++ b.dif, isa: MapSet.union(a.isa, b.isa)}

  defp empty_constraint_set(), do: %{dif: [], isa: MapSet.new()}

  # The constraint store: a var's constraints, kept as a structure of its own
  # rather than smuggled into `bindings` — `bindings` stays a plain
  # substitution map everything else in the codebase can keep reading
  # directly, and the store rides along on backtrack for free anyway, since a
  # choicepoint already snapshots itself wholesale rather than using a
  # WAM-style trail.
  @spec add_dif(constraints(), t(), t()) :: constraints()
  def add_dif(constraints, a, b) do
    a
    |> find_vars(find_vars(b))
    |> Enum.reduce(constraints, fn v, acc ->
      Map.update(acc, v, %{empty_constraint_set() | dif: [{a, b}]}, fn set ->
        %{set | dif: [{a, b} | set.dif]}
      end)
    end)
  end

  # `isa` is `dif`'s positive counterpart: instead of "never equal to this
  # term", "every future bind of this var must belong to `class`". Registered
  # wherever a dispatch leg commits an open var to a class before it's
  # necessarily grounded (see `AL.Dispatch.do_send_as`) — a var routed through
  # `:number`'s value leg shouldn't be bindable to a durable object just
  # because it's still open when that leg returns.
  @spec add_isa(constraints(), variable(), atom()) :: constraints()
  def add_isa(constraints, var, class) do
    Map.update(constraints, var, %{empty_constraint_set() | isa: MapSet.new([class])}, fn set ->
      %{set | isa: MapSet.put(set.isa, class)}
    end)
  end

  @spec constraints_violated?(constraints(), bindings(), variable(), t(), AL.Branch.t()) ::
          boolean()
  defp constraints_violated?(constraints, bindings, var, term, branch) do
    case Map.get(constraints, var) do
      nil ->
        false

      set ->
        Enum.any?(set.dif, fn {a, b} -> subst(a, bindings) == subst(b, bindings) end) or
          (not var?(term) and Enum.any?(set.isa, &(not isa?(term, &1, branch))))
    end
  end

  # `:number`/`:list`/`:map` are decidable from `term`'s own shape — no lookup.
  # Every other class is a *relational fact* recorded separately in the
  # durable store (an object's own name carries no information about what
  # class it is — `:my_point_1` and `:my_widget_1` are indistinguishable as
  # terms), so verifying membership means asking that store: a lookup of
  # `term`'s own class/super chain (`AL.Dispatch.MethodOrder.method_scopes/2`)
  # — one object's own classification, not the scan generating durable
  # *candidates* needs (see al-dif-constraints memory for that distinction).
  defp isa?(term, :number, _branch), do: is_number(term)
  defp isa?(term, :list, _branch), do: is_list(term)
  defp isa?(term, :map, _branch), do: is_map(term)

  defp isa?(term, class, branch),
    do: class in AL.Dispatch.MethodOrder.method_scopes(term, branch)

  @spec occurs?(variable(), t(), bindings()) :: boolean()
  def occurs?(var, term, bindings) do
    term = if is_atom(term) or var?(term), do: deref(bindings, term), else: term

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

  @spec unify(t(), t(), bindings(), constraints(), AL.Branch.t()) ::
          {bindings(), constraints()} | nil
  def unify(x, y, bindings \\ %{}, constraints \\ %{}, branch \\ AL.Branch.head()) do
    cond do
      x == :"$_" || y == :"$_" ->
        {bindings, constraints}

      var?(x) || var?(y) ->
        extend(bindings, x, y, constraints, branch)

      is_list(x) && is_list(y) && x != [] && y != [] ->
        [x | xs] = x
        [y | ys] = y

        case unify(x, y, bindings, constraints, branch) do
          nil ->
            nil

          {next_bindings, next_constraints} ->
            unify(xs, ys, next_bindings, next_constraints, branch)
        end

      is_tuple(x) && is_tuple(y) && tuple_size(x) == tuple_size(y) ->
        unify(Tuple.to_list(x), Tuple.to_list(y), bindings, constraints, branch)

      is_map(x) && is_map(y) ->
        keys = Map.keys(x) |> MapSet.new() |> MapSet.intersection(MapSet.new(Map.keys(y)))

        unify(
          Enum.map(keys, fn k -> Map.get(x, k) end),
          Enum.map(keys, fn k -> Map.get(y, k) end),
          bindings,
          constraints,
          branch
        )

      x == y ->
        {bindings, constraints}

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
  defp subst_leaf({:"$fresh", _base, _scope} = leaf, bindings, rewrite_unbound) do
    case deref(bindings, leaf) do
      ^leaf ->
        rewrite_unbound.(leaf)

      other ->
        if var?(other), do: rewrite_unbound.(other), else: subst(other, bindings, rewrite_unbound)
    end
  end

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

  # Wrapping rather than minting keeps the atom table flat; a
  # re-freshened var nests, so distinct scopes stay distinct.
  @spec freshen(t(), String.t()) :: t()
  def freshen(term, f) do
    AL.Goal.map(term, fn
      :"$_" -> :"$_"
      {:"$fresh", _base, _scope} = leaf -> fresh(leaf, f)
      leaf -> if var?(leaf), do: fresh(leaf, f), else: leaf
    end)
  end
end
