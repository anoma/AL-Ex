defmodule AL.Var.ConstraintSet do
  @moduledoc """
  I am what a still-open var's store entry holds instead of a bound term — a
  struct, not a plain map, specifically so `AL.Var.deref/2` can tell "still
  open, here's what's known" apart from "bound to a term that happens to be a
  plain map" by shape alone: no AL-level term is ever a `%ConstraintSet{}` (AL
  values are atoms/numbers/binaries/lists/tuples/maps, never a tagged internal
  struct), so a bound entry needs no wrapper of its own — a bare bound term
  and this struct are already unambiguous by pattern match.
  """

  @type bound() :: integer() | nil
  @type propagator() :: {AL.Var.t(), AL.Var.t(), boolean()}

  @type t() :: %__MODULE__{
          dif: [{AL.Var.t(), AL.Var.t()}],
          isa: MapSet.t(atom()),
          bounds: {bound(), bound()},
          props: [propagator()]
        }

  defstruct dif: [], isa: MapSet.new(), bounds: {nil, nil}, props: []
end

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

  # One entry per var: a binding is just the maximally-specific case of "what's
  # known about this var's domain", not a different kind of fact from `dif`/
  # `isa` — standard CLP doesn't distinguish a substitution from a narrow
  # domain constraint, and neither does this store. A bound var's entry is the
  # bare term itself (this is a strict superset of the old plain bindings map
  # — anywhere that only ever bound vars, never touched `dif`/`isa`, is
  # already a valid store as-is); a still-open var carrying constraints holds
  # a `ConstraintSet`; absent from the map entirely means open with nothing
  # known yet.
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

  # Bind `var` to `term`, refusing (returning nil, i.e. unification failure) if
  # `var` occurs in `term` — the occurs check, which keeps cyclic terms out of
  # the store so `subst`/`deref` can't loop forever — or if the binding would
  # satisfy a `dif/2` or `isa` parked on `var` (see `add_dif/3`/`add_isa/3`).
  # This is the one choke point every unification in the VM passes through
  # (`extend/4` is `bind/4`'s only caller, `unify/4` is `extend/4`'s only
  # caller — dispatch's own candidate generation included, since every
  # candidate is offered via this same path), so it's the only place a
  # constraint check is guaranteed to see every bind regardless of how deep in
  # the interpreter it happens. `branch` only matters for `isa`: verifying a
  # durable class needs a lookup of the concrete term's own class row
  # (`AL.Dispatch.MethodOrder.method_scopes/2`) — cheap (one object's own
  # classification), not the scan generating durable *candidates* needs (see
  # al-dif-constraints memory).
  @spec bind(store(), variable(), t(), AL.Branch.t()) :: store() | nil
  defp bind(store, var, term, branch) do
    if occurs?(var, term, store) do
      nil
    else
      old_constraints = constraint_set(store, var)
      new_store = store |> Map.put(var, term) |> migrate_constraints(old_constraints, term)

      if violated?(old_constraints, new_store, term, branch) do
        nil
      else
        new_store
      end
    end
  end

  defp constraint_set(store, var) do
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
  # instead of falling back to a real scan for a receiver that, for an
  # ephemeral/value candidate, was never durably classified in the first place.
  @spec isa_of(store(), variable()) :: MapSet.t(atom())
  def isa_of(store, var) do
    case constraint_set(store, var) do
      nil -> MapSet.new()
      set -> set.isa
    end
  end

  # A var's already-propagated `{lo, hi}` interval, if any — the read side
  # `Goal.Label` uses to know what to enumerate. Ground terms have a trivial
  # singleton domain of themselves, same convention `domain/2` already uses
  # internally for narrowing.
  @spec bounds_of(store(), t()) :: {ConstraintSet.bound(), ConstraintSet.bound()}
  def bounds_of(store, term), do: domain(store, term)

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

  defp in_bounds?({lo, hi}, term), do: (lo == nil or term >= lo) and (hi == nil or term <= hi)

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

  # `< > <= >=` bounds consistency: each comparison narrows an interval
  # instead of only ever failing on a non-ground side. Registered as a
  # `propagator()` on every var either side mentions (same attach-to-every-
  # mentioned-var pattern as `dif`), then run through a worklist fixpoint —
  # narrowing one var re-queues every *other* propagator parked on it, so a
  # chain (`x < y, y < 5`) tightens `x` transitively without `x < y` ever
  # being re-evaluated by hand. A var whose bounds collapse to a single
  # value is bound outright through the same `bind/4` every other constraint
  # goes through (so a `dif`/`isa` obligation on it still gets checked), not
  # left as a width-1 interval no other goal would recognise as ground.
  @spec add_compare(store(), atom(), t(), t(), AL.Branch.t()) :: store() | nil
  def add_compare(store, op, a, b, branch) do
    {lo, hi, strict} = normalize(op, a, b)

    store
    |> register_propagator(lo, hi, strict)
    |> run_fixpoint(MapSet.new([{lo, hi, strict}]), branch)
  end

  defp normalize(:<, a, b), do: {a, b, true}
  defp normalize(:<=, a, b), do: {a, b, false}
  defp normalize(:>, a, b), do: {b, a, true}
  defp normalize(:>=, a, b), do: {b, a, false}

  defp register_propagator(store, lo, hi, strict) do
    prop = {lo, hi, strict}

    [lo, hi]
    |> Enum.map(&deref(store, &1))
    |> Enum.filter(&var?/1)
    |> Enum.uniq()
    |> Enum.reduce(store, fn v, acc ->
      Map.update(acc, v, %ConstraintSet{props: [prop]}, fn
        %ConstraintSet{} = set -> %{set | props: [prop | set.props]}
        other -> other
      end)
    end)
  end

  defp run_fixpoint(store, worklist, branch) do
    case Enum.at(worklist, 0) do
      nil ->
        store

      {lo, hi, strict} = t ->
        rest = MapSet.delete(worklist, t)

        case narrow_pair(store, lo, hi, strict, branch) do
          nil -> nil
          {new_store, more} -> run_fixpoint(new_store, MapSet.union(rest, more), branch)
        end
    end
  end

  # `lo <= hi` (or `lo < hi` if `strict`): narrow `hi`'s floor from `lo`'s
  # floor, and `lo`'s ceiling from `hi`'s ceiling — the two directions an
  # order constraint propagates in an interval domain.
  defp narrow_pair(store, lo, hi, strict, branch) do
    {lo_lo, lo_hi} = domain(store, lo)
    {hi_lo, hi_hi} = domain(store, hi)

    new_hi_bounds = {tighten_max(hi_lo, bump_up(lo_lo, strict)), hi_hi}
    new_lo_bounds = {lo_lo, tighten_min(lo_hi, bump_down(hi_hi, strict))}

    with {:ok, store1, hi_props} <- apply_domain(store, hi, new_hi_bounds, branch),
         {:ok, store2, lo_props} <- apply_domain(store1, lo, new_lo_bounds, branch) do
      {store2, MapSet.new(hi_props ++ lo_props)}
    else
      :fail -> nil
    end
  end

  defp domain(store, term) do
    case deref(store, term) do
      n when is_number(n) ->
        {n, n}

      v ->
        case constraint_set(store, v) do
          %ConstraintSet{bounds: b} -> b
          _ -> {nil, nil}
        end
    end
  end

  # Applies a freshly-narrowed `{lo, hi}` to one side of a comparison —
  # `term` may already be ground (just a feasibility check, no store change),
  # still open (record the tighter interval), or have just collapsed to a
  # single value (bind it, and hand back the propagators that *were* parked
  # on it before binding erased its `ConstraintSet`, so the caller's worklist
  # still visits them with the now-ground value).
  defp apply_domain(store, term, {new_lo, new_hi}, branch) do
    if new_lo != nil and new_hi != nil and new_lo > new_hi do
      :fail
    else
      case deref(store, term) do
        n when is_number(n) ->
          if in_bounds?({new_lo, new_hi}, n), do: {:ok, store, []}, else: :fail

        v ->
          old_bounds = domain(store, v)
          props = props_of(store, v)

          cond do
            {new_lo, new_hi} == old_bounds ->
              {:ok, store, []}

            new_lo != nil and new_lo == new_hi ->
              case bind(store, v, new_lo, branch) do
                nil -> :fail
                new_store -> {:ok, new_store, props}
              end

            true ->
              {:ok, set_bounds(store, v, {new_lo, new_hi}), props}
          end
      end
    end
  end

  defp props_of(store, v) do
    case constraint_set(store, v) do
      %ConstraintSet{props: props} -> props
      _ -> []
    end
  end

  defp set_bounds(store, v, bounds) do
    Map.update(store, v, %ConstraintSet{bounds: bounds}, fn
      %ConstraintSet{} = set -> %{set | bounds: bounds}
      other -> other
    end)
  end

  defp bump_up(nil, _strict), do: nil
  defp bump_up(n, true), do: n + 1
  defp bump_up(n, false), do: n

  defp bump_down(nil, _strict), do: nil
  defp bump_down(n, true), do: n - 1
  defp bump_down(n, false), do: n

  defp tighten_max(nil, x), do: x
  defp tighten_max(x, nil), do: x
  defp tighten_max(a, b), do: max(a, b)

  defp tighten_min(nil, x), do: x
  defp tighten_min(x, nil), do: x
  defp tighten_min(a, b), do: min(a, b)

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
