defmodule AL.Var do
  @moduledoc """
  I provide symbolic utilities for AL.

  Some terminology:

  The store is a forest of variable references where the leaves are ground
  terms and act as roots of the reference chain.

  Vars look like :"$<string>"; a freshened var wraps its original as
  {:"$fresh", base, scope}, so resolution mints no atoms.
  """

  alias AL.Var.ConstraintSet

  @type variable() :: atom() | {:"$fresh", variable(), String.t()}
  @type t() :: atom() | number() | binary() | [t()] | tuple() | map()

  # Binding = most-specific case of "what's known" about a var, same as
  # dif/isa, not a different kind of fact. Bound entry = bare term
  # (superset of old bindings-only maps). Open+constrained = ConstraintSet.
  # Absent = open, nothing known.
  @type entry() :: t() | ConstraintSet.t()
  @type store() :: %{optional(variable()) => entry()}

  @spec empty_store() :: store()
  def empty_store(), do: %{}

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

  @spec deref(store(), variable()) :: t()
  def deref(store, k) do
    case Map.get(store, k) do
      nil ->
        k

      %ConstraintSet{} ->
        k

      ^k ->
        k

      v ->
        if var?(v), do: deref(store, v), else: v
    end
  end

  @spec extend(store(), t(), t(), AL.Branch.t()) :: store() | nil
  def extend(store, x, y, branch) do
    rx = deref(store, x)
    ry = deref(store, y)

    is_var_rx = var?(rx)
    is_var_ry = var?(ry)

    cond do
      rx == ry -> store
      not is_var_rx && is_var_ry -> bind(store, ry, x, branch)
      rx == x && is_var_ry -> bind(store, ry, x, branch)
      not is_var_ry && is_var_rx -> bind(store, rx, y, branch)
      ry == y && is_var_rx -> bind(store, rx, y, branch)
      is_var_ry && is_var_rx -> bind(store, rx, ry, branch)
      true -> unify(rx, ry, store, branch)
    end
  end

  # Binds var to term. Occurs-check refuses cyclic terms; also refuses if it'd
  # violate a dif/isa/bounds constraint on var (add_dif/3, add_isa/3,
  # AL.Var.Bounds). Sole choke point every unify passes through (extend/4 ->
  # bind/4, unify/4 -> extend/4 only), so every bind is constraint-checked
  # here, however deep. def not defp: AL.Var.Bounds also binds directly
  # through this path — including recursively, from `propagate/3` below
  # (mutual recursion across the two modules, same pattern as
  # AL/AL.Dispatch/AL.Store elsewhere in this codebase).
  #
  # `term` is resolved here, once, before anything else touches it —
  # `extend/4`'s own branch selection sometimes passes a raw, still-var-shaped
  # reference (e.g. matching `[x|_t]` against `[h|t]` where `x` already
  # resolved to a concrete value earlier in the *same* unify call — `x` the
  # reference gets threaded through, not its value). `deref` is a no-op on
  # anything that isn't itself an atom/var reference, so this is a pure
  # resolve, not a behavior change to *what* gets bound — but it matters for
  # `violated?` below, whose isa/bounds check only ever fires `if not
  # var?(term)`: an unresolved reference reads as "still open" and silently
  # skips the check even when what it ultimately points to is concrete.
  @spec bind(store(), variable(), t(), AL.Branch.t()) :: store() | nil
  def bind(store, var, term, branch) do
    term = deref(store, term)

    if occurs?(var, term, store) do
      nil
    else
      old_constraints = constraint_set(store, var)
      new_store = store |> Map.put(var, term) |> migrate_constraints(old_constraints, term)

      case propagate(old_constraints, new_store, branch) do
        nil ->
          nil

        propagated_store ->
          if violated?(old_constraints, propagated_store, term, branch) do
            nil
          else
            propagated_store
          end
      end
    end
  end

  # A var's own `props` (from an earlier `eq`/`< > <= >=`) don't only fire
  # when another such call touches the same var again — an *ordinary* bind
  # (this one) re-triggers them too, so a var grounded via plain head
  # unification (a recursive clause's own base case, say) still wakes
  # whatever was waiting on it, instead of leaving a stale, unchecked
  # propagator sitting on a now-concrete value.
  defp propagate(nil, store, _branch), do: store
  defp propagate(%ConstraintSet{props: []}, store, _branch), do: store

  defp propagate(%ConstraintSet{props: props}, store, branch),
    do: AL.Var.Bounds.run_fixpoint(store, MapSet.new(props), branch)

  # `def`, not `defp` — `AL.Var.Bounds` reads a var's existing `ConstraintSet`
  # (its propagators, its current bounds) the same way `bind/4` does here.
  def constraint_set(store, var) do
    case Map.get(store, var) do
      %ConstraintSet{} = set -> set
      _ -> nil
    end
  end

  # `extend/4` picks which of two still-open vars becomes the alias and which
  # stays live by argument position, not by which one carries a constraint —
  # so a constrained var can end up retired in favour of a fresh one that has
  # never heard of it. Carry its constraints forward onto whichever var is
  # still live, or a later bind of the survivor alone would never see them.
  defp migrate_constraints(store, nil, _term), do: store

  defp migrate_constraints(store, constraint_set, term) do
    if var?(term) do
      Map.update(store, term, constraint_set, fn
        %ConstraintSet{} = existing -> merge_constraint_sets(existing, constraint_set)
        other -> other
      end)
    else
      store
    end
  end

  defp merge_constraint_sets(a, b),
    do: %ConstraintSet{
      dif: a.dif ++ b.dif,
      isa: MapSet.union(a.isa, b.isa),
      bounds: merge_bounds(a.bounds, b.bounds),
      props: a.props ++ b.props
    }

  defp merge_bounds({lo1, hi1}, {lo2, hi2}), do: {tighten_max(lo1, lo2), tighten_min(hi1, hi2)}

  # The constraint store: a var's constraints are their own entry kind, not
  # smuggled into an ordinary bound value — that's what `ConstraintSet` being
  # a distinct struct buys, not a separate map. A binding and a constraint set
  # are both just store entries, differing only in how narrow the domain they
  # describe is, and both ride along on backtrack for free, since a
  # choicepoint already snapshots itself wholesale rather than using a
  # WAM-style trail.
  @spec add_dif(store(), t(), t()) :: store()
  def add_dif(store, a, b) do
    a
    |> find_vars(find_vars(b))
    |> Enum.reduce(store, fn v, acc ->
      Map.update(acc, v, %ConstraintSet{dif: [{a, b}]}, fn
        %ConstraintSet{} = set -> %{set | dif: [{a, b} | set.dif]}
        other -> other
      end)
    end)
  end

  # `isa` is `dif`'s positive counterpart: instead of "never equal to this
  # term", "every future bind of this var must belong to `class`". Registered
  # wherever a dispatch leg commits an open var to a class before it's
  # necessarily grounded (see `AL.Dispatch.generative_candidate`) — a var
  # routed through `:number`'s value leg shouldn't be bindable to a durable
  # object just because it's still open when that leg returns.
  @spec add_isa(store(), variable(), atom()) :: store()
  def add_isa(store, var, class) do
    Map.update(store, var, %ConstraintSet{isa: MapSet.new([class])}, fn
      %ConstraintSet{} = set -> %{set | isa: MapSet.put(set.isa, class)}
      other -> other
    end)
  end

  # A var's already-known class domain, if any — the read side of `add_isa/3`.
  # Lets a query (e.g. `AL.Relations`'s `GetClass` asked for self's class with
  # the class side still open) answer directly from what's already known
  # instead of falling back to a real scan for a receiver that, as a value
  # candidate, was never durably classified in the first place.
  @spec isa_of(store(), variable()) :: MapSet.t(atom())
  def isa_of(store, var) do
    case constraint_set(store, var) do
      nil -> MapSet.new()
      set -> set.isa
    end
  end

  defp violated?(nil, _store, _term, _branch), do: false
  defp violated?(set, store, term, branch), do: find_violation(set, store, term, branch) != nil

  # Shared core between `bind/4`'s own reactive check and the public
  # `constraint_violation/4`: both need "this var's constraint set, resolved
  # against a store where `term` is hypothetically its value" — but the
  # constraint set has to be looked up *before* that hypothetical bind
  # overwrites the var's entry (a bound term and a `ConstraintSet` are the
  # same store slot), so callers always pass the set they already found
  # separately, not re-derive it from `store` here.
  defp find_violation(%ConstraintSet{dif: dif, isa: isa, bounds: bounds}, store, term, branch) do
    case Enum.find(dif, fn {a, b} -> subst(a, store) == subst(b, store) end) do
      {a, b} ->
        {:dif, a, b}

      nil ->
        if not var?(term) do
          cond do
            not in_bounds?(bounds, term) ->
              {:bounds, bounds}

            (class = Enum.find(isa, &(not isa?(term, &1, branch)))) != nil ->
              {:isa, class}

            true ->
              nil
          end
        end
    end
  end

  # `def`, not `defp` — `AL.Var.Bounds` uses the same in-bounds feasibility
  # check when applying a freshly-narrowed interval, not just the constraint
  # violation check here.
  def in_bounds?({lo, hi}, term), do: (lo == nil or term >= lo) and (hi == nil or term <= hi)

  # `def`, not `defp` — this is also the diagnostic entry point
  # (`diagnose_unify_failure/4`) uses to explain *why* a bind was refused, not
  # just that `bind/4` returned `nil`. Returns the first violated constraint,
  # not just a boolean, so a caller can report which one. Looks up `var`'s
  # constraint set from `store` *before* hypothetically binding it to `term`
  # for the `dif` resolution below — same ordering `bind/4` uses, and for the
  # same reason: binding `var` first would overwrite the very `ConstraintSet`
  # entry this needs to read.
  @spec constraint_violation(store(), variable(), t(), AL.Branch.t()) ::
          {:dif, t(), t()} | {:isa, atom()} | nil
  def constraint_violation(store, var, term, branch) do
    case constraint_set(store, var) do
      nil -> nil
      set -> find_violation(set, Map.put(store, var, term), term, branch)
    end
  end

  # A user-facing "why did `unify(x, y)` just fail" explanation, distinct from
  # `bind/4`'s own internal check: covers the common, legible shape (one side
  # a still-open var carrying a constraint, the other already concrete) rather
  # than trying to replicate `extend/4`'s full var-vs-var aliasing logic — a
  # var-vs-var or both-already-concrete mismatch returns `nil` (no diagnosis
  # offered) rather than guessing. Only meaningful to call *after* `unify`
  # itself has already returned `nil` for this exact `x`/`y` — it does not
  # unify anything itself.
  @spec diagnose_unify_failure(t(), t(), store(), AL.Branch.t()) ::
          {:dif, t(), t()} | {:isa, variable(), atom()} | nil
  def diagnose_unify_failure(x, y, store, branch) do
    rx = deref(store, x)
    ry = deref(store, y)

    cond do
      var?(rx) and not var?(ry) ->
        tag_isa(constraint_violation(store, rx, ry, branch), rx)

      var?(ry) and not var?(rx) ->
        tag_isa(constraint_violation(store, ry, rx, branch), ry)

      true ->
        nil
    end
  end

  defp tag_isa({:isa, class}, var), do: {:isa, var, class}
  defp tag_isa(other, _var), do: other

  # `:number`/`:list`/`:map` are decidable from `term`'s own shape — no
  # lookup. A value class beyond those three is provable by matching one of
  # its own clause heads in the self position (`AL.Dispatch.value_member?/3`)
  # — `:letter_chain`'s bare-atom `:a`/`:b` were never durably classified,
  # matching one of its own clauses is the only evidence of membership there
  # is. Every other class is a *relational fact* recorded separately in the
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
    do:
      class in AL.Dispatch.MethodOrder.method_scopes(term, branch) or
        AL.Dispatch.value_member?(term, class, branch)

  # `def`, not `defp` — `AL.Var.Bounds`' own narrowing fixpoint (`< > <= >=`
  # consistency, including through affine `+ - *` expressions) uses these
  # same nil-safe merges; `merge_bounds/2` above needs them regardless of
  # that module, so there's one definition rather than two copies drifting.
  def tighten_max(nil, x), do: x
  def tighten_max(x, nil), do: x
  def tighten_max(a, b), do: max(a, b)

  def tighten_min(nil, x), do: x
  def tighten_min(x, nil), do: x
  def tighten_min(a, b), do: min(a, b)

  @spec occurs?(variable(), t(), store()) :: boolean()
  def occurs?(var, term, store) do
    term = if is_atom(term) or var?(term), do: deref(store, term), else: term

    cond do
      var?(term) -> term == var
      # handle cons cells directly so improper lists (`[h | $tail]`) work
      is_list(term) -> occurs_in_list?(var, term, store)
      is_tuple(term) -> occurs_in_list?(var, Tuple.to_list(term), store)
      is_map(term) -> occurs_in_list?(var, Map.values(term), store)
      true -> false
    end
  end

  defp occurs_in_list?(var, [head | tail], store),
    do: occurs?(var, head, store) or occurs_in_list?(var, tail, store)

  defp occurs_in_list?(_var, [], _store), do: false

  defp occurs_in_list?(var, tail, store), do: occurs?(var, tail, store)

  @spec unify(t(), t(), store(), AL.Branch.t()) :: store() | nil
  def unify(x, y, store \\ %{}, branch \\ AL.Branch.head()) do
    cond do
      x == :"$_" || y == :"$_" ->
        store

      var?(x) || var?(y) ->
        extend(store, x, y, branch)

      is_list(x) && is_list(y) && x != [] && y != [] ->
        [x | xs] = x
        [y | ys] = y

        case unify(x, y, store, branch) do
          nil -> nil
          new_store -> unify(xs, ys, new_store, branch)
        end

      is_tuple(x) && is_tuple(y) && tuple_size(x) == tuple_size(y) ->
        unify(Tuple.to_list(x), Tuple.to_list(y), store, branch)

      is_map(x) && is_map(y) ->
        keys = Map.keys(x) |> MapSet.new() |> MapSet.intersection(MapSet.new(Map.keys(y)))

        unify(
          Enum.map(keys, fn k -> Map.get(x, k) end),
          Enum.map(keys, fn k -> Map.get(y, k) end),
          store,
          branch
        )

      x == y ->
        store

      true ->
        nil
    end
  end

  @spec subst(t(), store()) :: t()
  def subst(term, store), do: subst(term, store, & &1)

  # `rewrite_unbound` lets a caller rename a var that's still unbound after
  # dereferencing (e.g. AL.eval's display layer, which maps an internal freshened
  # var back to whichever observable query var it's aliased to) instead of
  # showing it as-is.
  @spec subst(t(), store(), (variable() -> t())) :: t()
  def subst(term, store, rewrite_unbound),
    do: AL.Goal.map(term, &subst_leaf(&1, store, rewrite_unbound))

  # A bound var derefs to its term, which is itself substituted
  defp subst_leaf({:"$fresh", _base, _scope} = leaf, store, rewrite_unbound) do
    case deref(store, leaf) do
      ^leaf ->
        rewrite_unbound.(leaf)

      other ->
        if var?(other), do: rewrite_unbound.(other), else: subst(other, store, rewrite_unbound)
    end
  end

  defp subst_leaf(leaf, store, rewrite_unbound) when is_atom(leaf) do
    case deref(store, leaf) do
      ^leaf ->
        if var?(leaf), do: rewrite_unbound.(leaf), else: leaf

      other ->
        if var?(other), do: rewrite_unbound.(other), else: subst(other, store, rewrite_unbound)
    end
  end

  defp subst_leaf(leaf, _store, _rewrite_unbound), do: leaf

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
