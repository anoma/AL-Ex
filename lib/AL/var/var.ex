defmodule AL.Var do
  @moduledoc """
  I provide symbolic utilities for AL.

  Some terminology:

  The store is a forest of variable references where the leaves are ground
  terms and act as roots of the reference chain.

  Vars look like {:"$var", "<string>"}; a freshened var wraps its original as
  {:"$fresh", base, scope}, so resolution mints no atoms.
  """

  alias AL.Var.ConstraintSet
  @compile {:inline, deref: 2}

  @type variable() :: {:"$var", String.t()} | {:"$fresh", variable(), String.t()}
  @type t() :: atom() | number() | binary() | maybe_improper_list(t(), t()) | tuple() | map()

  # Binding = most-specific case of "what's known" about a var, same as
  # dif/isa, not a different kind of fact. Bound entry = bare term
  # (superset of old bindings-only maps). Open+constrained = ConstraintSet.
  # Absent = open, nothing known.
  @type entry() :: t() | ConstraintSet.t()
  @type store() :: %{optional(variable()) => entry()}

  def dif_value(a, b, store, branch) do
    case unify(a, b, store, branch) do
      nil -> store
      ^store -> nil
      _ -> add_dif(store, subst(a, store), subst(b, store))
    end
  end

  @spec empty_store() :: store()
  def empty_store(), do: %{}

  @spec var?(term()) :: boolean()
  def var?({:"$fresh", _base, _scope}), do: true

  def var?({:"$var", name}) when is_binary(name), do: true

  def var?(_x) do
    false
  end

  @spec var(String.t() | atom()) :: variable()
  def var(x) do
    {:"$var", to_string(x)}
  end

  @spec name(variable()) :: String.t()
  def name({:"$fresh", base, scope}), do: name(base) <> "_" <> scope

  def name({:"$var", name}), do: name

  def key(variable), do: "$" <> name(variable)

  @spec fresh(variable(), String.t()) :: variable()
  def fresh(base, scope), do: {:"$fresh", base, scope}

  @spec deref(store(), t()) :: t()
  defdelegate deref(store, variable), to: AL.Var.Store

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
  # AL/AL.Dispatch/AL.JAM.Mutation elsewhere in this codebase).
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
    resolved = deref(store, term)

    if ground_marked?(store, term) do
      bind_ground(store, var, resolved, branch)
    else
      case scan(var, resolved, store) do
        :occurs -> nil
        :ground -> bind_ground(store, var, resolved, branch)
        :open -> bind_resolved(store, var, resolved, branch)
      end
    end
  end

  defp bind_ground(store, var, term, branch) do
    case bind_resolved(store, var, term, branch) do
      nil -> nil
      new_store -> mark_ground(new_store, var)
    end
  end

  @ground_marks AL.Var.GroundMarks

  defp ground_marked?(store, term) do
    var?(term) and Map.has_key?(Map.get(store, @ground_marks, %{}), term)
  end

  defp mark_ground(store, var) do
    case Map.get(store, var) do
      [_ | _] -> Map.update(store, @ground_marks, %{var => true}, &Map.put(&1, var, true))
      _scalar -> store
    end
  end

  defp bind_resolved(store, var, term, branch) do
    old_constraints = constraint_set(store, var)
    new_store = store |> Map.put(var, term) |> migrate_constraints(old_constraints, term)

    with propagated_store when not is_nil(propagated_store) <-
           propagate(old_constraints, new_store, branch),
         keyed_store when not is_nil(keyed_store) <-
           propagate_keys(old_constraints, term, propagated_store, branch),
         functor_store when not is_nil(functor_store) <-
           propagate_functor(old_constraints, term, keyed_store, branch),
         linked_store when not is_nil(linked_store) <-
           propagate_links(old_constraints, term, functor_store, branch) do
      if violated?(old_constraints, linked_store, term, branch) do
        nil
      else
        linked_store
      end
    else
      nil -> nil
    end
  end

  defp propagate_keys(nil, _term, store, _branch), do: store

  defp propagate_keys(%ConstraintSet{keys: keys}, _term, store, _branch) when keys == %{},
    do: store

  defp propagate_keys(%ConstraintSet{keys: keys}, term, store, branch) do
    Enum.reduce_while(keys, store, fn {key, value}, acc ->
      case add_key(acc, term, key, value, branch) do
        nil -> {:halt, nil}
        next -> {:cont, next}
      end
    end)
  end

  @spec add_key(store(), t(), t(), t(), AL.Branch.t()) :: store() | nil
  def add_key(store, map, key, value, branch) do
    case deref(store, map) do
      bound when is_map(bound) and not is_struct(bound) ->
        case Map.fetch(bound, key) do
          {:ok, existing} -> unify(value, existing, store, branch)
          :error -> nil
        end

      open ->
        if var?(open), do: record_key(store, open, key, value, branch), else: nil
    end
  end

  defp record_key(store, var, key, value, branch) do
    case constraint_set(store, var) do
      %ConstraintSet{keys: %{^key => existing}} ->
        unify(value, existing, store, branch)

      %ConstraintSet{} = set ->
        Map.put(store, var, %{set | keys: Map.put(set.keys, key, value)})

      nil ->
        Map.put(store, var, %ConstraintSet{keys: %{key => value}})
    end
  end

  defp propagate_functor(nil, _term, store, _branch), do: store

  defp propagate_functor(
         %ConstraintSet{functor: functor, functor_links: links},
         term,
         store,
         branch
       ) do
    store =
      case functor do
        nil -> store
        {name, args} -> add_functor(store, term, name, args, branch)
      end

    Enum.reduce_while(links, store, fn linked, acc ->
      case acc && resolve_functor(acc, linked, branch) do
        nil -> {:halt, nil}
        next -> {:cont, next}
      end
    end)
  end

  @spec add_functor(store(), t(), t(), t(), AL.Branch.t()) :: store() | nil
  def add_functor(store, term, name, args, branch) do
    resolved = deref(store, term)

    if var?(resolved) do
      record_functor(store, resolved, name, args, branch)
    else
      case AL.Goal.call_form(resolved) do
        {term_name, term_args} ->
          unify([name, args], [term_name, term_args], store, branch)

        nil ->
          nil
      end
    end
  end

  defp record_functor(store, var, name, args, branch) do
    recorded =
      case constraint_set(store, var) do
        %ConstraintSet{functor: {known_name, known_args}} ->
          unify([name, args], [known_name, known_args], store, branch)

        %ConstraintSet{} = set ->
          store |> Map.put(var, %{set | functor: {name, args}}) |> add_isa(var, :compound)

        nil ->
          store |> Map.put(var, %ConstraintSet{functor: {name, args}}) |> add_isa(var, :compound)
      end

    recorded && resolve_functor(recorded, var, branch)
  end

  defp resolve_functor(store, var, branch) do
    with resolved <- deref(store, var),
         true <- var?(resolved),
         %ConstraintSet{functor: {name, args}} <- constraint_set(store, resolved) do
      build_functor(store, resolved, deref(store, name), spine(store, args, []), branch)
    else
      _ -> store
    end
  end

  defp build_functor(store, var, name, {:proper, args}, branch) do
    cond do
      var?(name) ->
        link_functor(store, name, var)

      is_atom(name) ->
        unify(var, AL.Goal.from_call_form(name, subst(args, store)), store, branch)

      true ->
        nil
    end
  end

  defp build_functor(store, var, name, {:open, tail}, _branch) do
    store = link_functor(store, tail, var)
    if var?(name), do: link_functor(store, name, var), else: store
  end

  defp build_functor(_store, _var, _name, :improper, _branch), do: nil

  defp spine(store, list, acc) do
    case deref(store, list) do
      [] -> {:proper, Enum.reverse(acc)}
      [head | tail] -> spine(store, tail, [head | acc])
      other -> if var?(other), do: {:open, other}, else: :improper
    end
  end

  defp link_functor(store, link, term_var) do
    Map.update(store, link, %ConstraintSet{functor_links: [term_var]}, fn
      %ConstraintSet{} = set -> %{set | functor_links: Enum.uniq([term_var | set.functor_links])}
      other -> other
    end)
  end

  # `var`'s own `super_link`/`slot_link` (captured in `old_constraints`,
  # before this bind overwrote its entry) may have a partner that's now
  # cheaply resolvable -- one side just became concrete (`term`), so what
  # used to require a full scan (both sides open) is now a targeted lookup
  # (`AL.JAM.Relation`'s `super` and `slot` relations already treat exactly this as
  # cheap). Only auto-binds when that lookup is genuinely unique; several
  # matches leave the partner exactly as open as it was -- not a failure,
  # it just isn't determined yet. Recurses through `bind/4` itself when it
  # *does* propagate, so a chain of links cascades for free, no explicit
  # worklist needed the way `AL.Var.Bounds`'s numeric fixpoint requires for
  # its own, structurally different (affine-sum) propagators. A bind with
  # neither link set (the overwhelming majority) costs two no-op pattern
  # matches, no scan.
  @spec propagate_links(ConstraintSet.t() | nil, t(), store(), AL.Branch.t()) :: store() | nil
  defp propagate_links(nil, _term, store, _branch), do: store

  defp propagate_links(%ConstraintSet{} = old, term, store, branch) do
    case propagate_super_link(old.super_link, term, store, branch) do
      nil -> nil
      store1 -> propagate_slot_links(old.slot_links, term, store1, branch)
    end
  end

  defp propagate_super_link(nil, _term, store, _branch), do: store

  defp propagate_super_link({:super, z}, object_value, store, branch),
    do: resolve_super_link(store, object_value, z, branch)

  defp propagate_super_link({:object, y}, super_value, store, branch),
    do: resolve_super_link(store, y, super_value, branch)

  defp resolve_super_link(store, object, super_, branch) do
    object_pat = deref(store, object)
    super_pat = deref(store, super_)

    case {var?(object_pat), var?(super_pat)} do
      {true, false} -> resolve_unique_super(store, object_pat, super_pat, branch)
      {false, true} -> resolve_unique_super(store, object_pat, super_pat, branch)
      _ -> store
    end
  end

  defp resolve_unique_super(store, object_pat, super_pat, branch) do
    case AL.Object.scan_super(object_pat, super_pat, branch) do
      [{:super, obj, _seq, sup}] ->
        {target_var, target_val} =
          if var?(object_pat), do: {object_pat, obj}, else: {super_pat, sup}

        bind(store, target_var, target_val, branch)

      _ ->
        store
    end
  end

  defp propagate_slot_link(nil, _term, store, _branch), do: store

  defp propagate_slot_link({:slot, key, value_var}, object_value, store, branch),
    do: resolve_slot_link(store, object_value, key, value_var, branch)

  defp propagate_slot_link({:slot_value, key, object_var}, value_value, store, branch),
    do: resolve_slot_link(store, object_var, key, value_value, branch)

  defp propagate_slot_links(links, term, store, branch) do
    Enum.reduce_while(links, store, fn link, acc ->
      case propagate_slot_link(link, term, acc, branch) do
        nil -> {:halt, nil}
        next -> {:cont, next}
      end
    end)
  end

  defp resolve_slot_link(store, object, key, value, branch) do
    object_pat = deref(store, object)
    value_pat = deref(store, value)

    case {var?(object_pat), var?(value_pat)} do
      # The value just became known -- several objects can share it, so
      # only auto-bind the object side if exactly one real object does.
      {true, false} -> resolve_unique_slot_value(store, object_pat, key, value_pat, branch)
      # The object just became known -- its slots row is a single, keyed
      # lookup, always resolvable outright if the key is set at all.
      {false, true} -> resolve_slot_from_object(store, object_pat, key, value_pat, branch)
      {false, false} -> resolve_slot_from_object(store, object_pat, key, value_pat, branch)
      _ -> store
    end
  end

  defp resolve_slot_from_object(store, object, key, value, branch) do
    fetched =
      if is_map(object) do
        Map.fetch(object, key)
      else
        case AL.Object.read_slots(object, branch) do
          [{:slots, ^object, slots}] when is_map(slots) -> Map.fetch(slots, key)
          _ -> :error
        end
      end

    case fetched do
      {:ok, resolved} -> unify(value, resolved, store, branch)
      :error -> nil
    end
  end

  defp resolve_unique_slot_value(store, object_var, key, value, branch) do
    object_var
    |> AL.Object.scan_slots({:"$var", "slot_propagate_scan"}, branch)
    |> Enum.filter(fn {:slots, _object, m} -> is_map(m) and Map.get(m, key) == value end)
    |> case do
      [{:slots, object, _m}] -> bind(store, object_var, object, branch)
      _ -> store
    end
  end

  # A var's own `props` (from an earlier `=`/`< > <= >=`) don't only fire
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
  defdelegate constraint_set(store, var), to: AL.Var.Store, as: :constraints

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
      direct_class: MapSet.union(a.direct_class, b.direct_class),
      isa: MapSet.union(a.isa, b.isa),
      dispatch: MapSet.union(a.dispatch, b.dispatch),
      bounds: merge_bounds(a.bounds, b.bounds),
      props: a.props ++ b.props,
      domain: merge_domains(a.domain, b.domain),
      super_link: a.super_link || b.super_link,
      slot_links: Enum.uniq(a.slot_links ++ b.slot_links),
      keys: a.keys,
      functor: a.functor,
      functor_links: Enum.uniq(a.functor_links ++ b.functor_links)
    }

  defp merge_domains(nil, d), do: d
  defp merge_domains(d, nil), do: d
  defp merge_domains(d1, d2), do: MapSet.intersection(d1, d2)

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
  # term", "every future bind of this var must belong to `class`".
  #
  # `class` doesn't have to be resolved yet -- `class(x, y)` with both
  # sides open posts `y` itself as an isa entry on `x` (and symmetrically `x`
  # on `y`), the same way `dif/2` already stores a pair that may still
  # contain open vars on either side. Every reader of `isa` (the bind-time
  # violation check, `isa_conflict?/3`, labeling) treats a still-open entry
  # as "not resolved yet, imposes nothing until it is" rather than assuming
  # every entry is already a usable class atom.
  @spec add_isa(store(), variable(), AL.Var.ConstraintSet.isa_entry()) :: store()
  def add_isa(store, var, class) do
    Map.update(store, var, %ConstraintSet{isa: MapSet.new([class])}, fn
      %ConstraintSet{} = set -> %{set | isa: MapSet.put(set.isa, class)}
      other -> other
    end)
  end

  @spec add_direct_class(store(), variable(), AL.Var.t()) :: {store(), MapSet.t(AL.Var.t())}
  def add_direct_class(store, var, class) do
    classes = MapSet.put(direct_classes_of(store, var), class)

    new_store =
      Map.update(store, var, %ConstraintSet{direct_class: classes}, fn
        %ConstraintSet{} = set -> %{set | direct_class: classes}
        other -> other
      end)

    {new_store, classes}
  end

  @spec direct_classes_of(store(), variable()) :: MapSet.t(AL.Var.t())
  def direct_classes_of(store, var) do
    case constraint_set(store, var) do
      nil -> MapSet.new()
      set -> set.direct_class
    end
  end

  @spec direct_class_conflict?(store(), variable()) :: boolean()
  def direct_class_conflict?(store, var) do
    store
    |> direct_classes_of(var)
    |> Enum.map(&deref(store, &1))
    |> Enum.reject(&var?/1)
    |> Enum.uniq()
    |> length()
    |> Kernel.>(1)
  end

  # Intersects `{lo, hi}` into whatever bounds `var` already carries (via
  # `tighten_max`/`tighten_min`, the same narrowing `AL.Var.Bounds` itself
  # uses for a `< > <= >=` propagator) rather than overwriting them --
  # a var reaching this with existing bounds from an unrelated constraint
  # earlier in the same query (e.g. `t > 100` posted before a relation also
  # posts `t`'s bounds from a matched row) must keep both, not lose one.
  # Same division of labor as `add_isa`: this only ever narrows, it doesn't
  # check the result is still feasible (`lo <= hi`) -- callers building a
  # choicepoint from this check that themselves and fail the choicepoint if
  # not, the same way `isa_conflict?/3` is a separate check from `add_isa`.
  @spec add_bounds(store(), variable(), {ConstraintSet.bound(), ConstraintSet.bound()}) ::
          store()
  def add_bounds(store, var, {lo, hi}) do
    Map.update(store, var, %ConstraintSet{bounds: {lo, hi}}, fn
      %ConstraintSet{bounds: {old_lo, old_hi}} = set ->
        %{set | bounds: {tighten_max(old_lo, lo), tighten_min(old_hi, hi)}}

      other ->
        other
    end)
  end

  # A var's already-known class domain, if any — the read side of `add_isa/3`.
  # Lets a query (e.g. `AL.JAM.Relation`'s `class` relation asked for self's class with
  # the class side still open) answer directly from what's already known
  # instead of falling back to a real scan for a receiver that, as a value
  # candidate, was never durably classified in the first place.
  @spec isa_of(store(), variable()) :: MapSet.t(AL.Var.ConstraintSet.isa_entry())
  def isa_of(store, var) do
    case constraint_set(store, var) do
      nil -> MapSet.new()
      set -> set.isa
    end
  end

  @spec add_dispatch(store(), variable(), atom(), atom()) :: store()
  def add_dispatch(store, var, selector, provider) do
    entry = {selector, provider}

    Map.update(store, var, %ConstraintSet{dispatch: MapSet.new([entry])}, fn
      %ConstraintSet{} = set -> %{set | dispatch: MapSet.put(set.dispatch, entry)}
      other -> other
    end)
  end

  @spec dispatch_of(store(), variable()) :: MapSet.t(ConstraintSet.dispatch_entry())
  def dispatch_of(store, var) do
    case constraint_set(store, var) do
      nil -> MapSet.new()
      set -> set.dispatch
    end
  end

  # `super(y, z)` with both sides open (`AL.JAM.Relation`'s `super` relation) posts one
  # of these on each side instead of scanning -- see `ConstraintSet.super_link/0`
  # for why this can't just reuse `isa` the way `class/2` does (the two
  # slots are the same domain, so there's no asymmetric "instance of" claim
  # to make on either side, just "which slot am I").
  @spec add_super_link(store(), variable(), ConstraintSet.super_link()) :: store()
  def add_super_link(store, var, link) do
    Map.update(store, var, %ConstraintSet{super_link: link}, fn
      %ConstraintSet{} = set -> %{set | super_link: link}
      other -> other
    end)
  end

  # The read side of `add_super_link/3` -- `nil` if this var was never one
  # end of a pending `super(y, z)`.
  @spec super_link_of(store(), variable()) :: ConstraintSet.super_link() | nil
  def super_link_of(store, var) do
    case constraint_set(store, var) do
      nil -> nil
      set -> set.super_link
    end
  end

  # `slot(object, key, value)` with `object` open and `key` ground
  # (`AL.JAM.Relation`'s `slot` relation) posts one of these -- `{:slot, key, value}` on
  # `object`, `{:slot_value, key, object}` on `value` if it's also open.
  # Same shape as `super_link` (a directional tag, not an isa claim), `key`
  # just rides along as fixed context rather than needing its own slot.
  @spec add_slot_link(store(), variable(), ConstraintSet.slot_link(), AL.Branch.t()) ::
          store() | nil
  def add_slot_link(store, var, link, branch) do
    resolved = deref(store, var)

    if var?(resolved) do
      with reconciled when not is_nil(reconciled) <-
             reconcile_slot_link(store, resolved, link, branch) do
        resolved = deref(reconciled, resolved)

        if var?(resolved) do
          Map.update(reconciled, resolved, %ConstraintSet{slot_links: [link]}, fn
            %ConstraintSet{} = set -> %{set | slot_links: Enum.uniq([link | set.slot_links])}
            other -> other
          end)
        else
          propagate_slot_link(link, resolved, reconciled, branch)
        end
      end
    else
      propagate_slot_link(link, resolved, store, branch)
    end
  end

  defp reconcile_slot_link(store, var, {:slot, key, value}, branch) do
    store
    |> slot_links_of(var)
    |> Enum.reduce_while(store, fn
      {:slot, ^key, existing}, acc ->
        case unify(value, existing, acc, branch) do
          nil -> {:halt, nil}
          next -> {:cont, next}
        end

      _link, acc ->
        {:cont, acc}
    end)
  end

  defp reconcile_slot_link(store, _var, _link, _branch), do: store

  # The read side of `add_slot_link/4` -- `[]` if this var was never one
  # end of a pending `slot(object, key, value)`.
  @spec slot_links_of(store(), variable()) :: [ConstraintSet.slot_link()]
  def slot_links_of(store, var) do
    case constraint_set(store, var) do
      nil -> []
      set -> set.slot_links
    end
  end

  # `in_domain/2`'s constraint: "var must end up being one of these" — same
  # slot as isa/dif/bounds, intersects with whatever's already there rather
  # than replacing, so two `in_domain` posts on the same var narrow together
  # instead of only the second one counting. Returns the narrowed domain
  # alongside the store so the caller (Goal.InDomain's interp) can tell empty
  # (infeasible) apart from singleton (auto-bind) apart from still-open.
  @spec add_domain(store(), variable(), [t()]) :: {store(), MapSet.t(t())}
  def add_domain(store, var, values) do
    new_values = MapSet.new(values)

    narrowed =
      case constraint_set(store, var) do
        %ConstraintSet{domain: nil} -> new_values
        %ConstraintSet{domain: existing} -> MapSet.intersection(existing, new_values)
        nil -> new_values
      end

    new_store =
      Map.update(store, var, %ConstraintSet{domain: narrowed}, fn
        %ConstraintSet{} = set -> %{set | domain: narrowed}
        other -> other
      end)

    {new_store, narrowed}
  end

  # Read side of `add_domain/3` — `nil` (no explicit domain) is distinct from
  # an empty set (domain narrowed to nothing, infeasible).
  @spec domain_of(store(), variable()) :: MapSet.t(t()) | nil
  def domain_of(store, var) do
    case constraint_set(store, var) do
      nil -> nil
      set -> set.domain
    end
  end

  @spec narrow_domain(store(), variable(), AL.Branch.t()) ::
          {store(), MapSet.t(t()) | nil}
  def narrow_domain(store, var, branch) do
    case domain_of(store, var) do
      nil ->
        {store, nil}

      domain ->
        narrowed =
          Enum.reduce(domain, MapSet.new(), fn candidate, acc ->
            if constraint_violation(store, var, candidate, branch) == nil,
              do: MapSet.put(acc, candidate),
              else: acc
          end)

        new_store =
          Map.update(store, var, %ConstraintSet{domain: narrowed}, fn
            %ConstraintSet{} = set -> %{set | domain: narrowed}
            other -> other
          end)

        {new_store, narrowed}
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
  defp find_violation(
         %ConstraintSet{
           dif: dif,
           direct_class: direct_class,
           isa: isa,
           dispatch: dispatch,
           bounds: bounds,
           domain: domain
         },
         store,
         term,
         branch
       ) do
    case Enum.find(dif, fn {a, b} -> subst(a, store) == subst(b, store) end) do
      {a, b} ->
        {:dif, a, b}

      nil ->
        if not var?(term) do
          cond do
            not in_bounds?(bounds, term) ->
              {:bounds, bounds}

            (class =
               Enum.find_value(direct_class, fn raw_class ->
                 class = deref(store, raw_class)

                 if not var?(class) and not AL.Dispatch.direct_class?(term, class, branch),
                   do: class
               end)) != nil ->
              {:class, class}

            (class = Enum.find_value(isa, &isa_violation_class(&1, term, store, branch))) != nil ->
              {:isa, class}

            (entry =
               Enum.find(dispatch, fn {selector, provider} ->
                 AL.Dispatch.selected_provider(term, selector, branch) != provider
               end)) != nil ->
              {:dispatch, entry}

            domain != nil and not MapSet.member?(domain, term) ->
              {:domain, domain}

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
          {:dif, t(), t()} | {:class, atom()} | {:isa, atom()} | nil
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
          {:dif, t(), t()} | {:class, variable(), atom()} | {:isa, variable(), atom()} | nil
  def diagnose_unify_failure(x, y, store, branch) do
    rx = deref(store, x)
    ry = deref(store, y)

    cond do
      var?(rx) and not var?(ry) ->
        tag_class_constraint(constraint_violation(store, rx, ry, branch), rx)

      var?(ry) and not var?(rx) ->
        tag_class_constraint(constraint_violation(store, ry, rx, branch), ry)

      true ->
        nil
    end
  end

  defp tag_class_constraint({:class, class}, var), do: {:class, var, class}
  defp tag_class_constraint({:isa, class}, var), do: {:isa, var, class}
  defp tag_class_constraint(other, _var), do: other

  # `{:object_link, obj}` (posted on the *class* side of a still-open
  # `class(x, y)`, see `AL.JAM.Relation`'s `class` relation) never asserts "I belong
  # to a class" at all -- it's a directional marker, not an isa claim, so it
  # can never be violated. Without this clause, once `obj` (or whatever it
  # gets bound to) derefs to something concrete, the fallback clause below
  # would wrongly treat *that* as a class name to check membership against
  # (e.g. "is `:program_execution` an instance of `:bootstrap`") and reject an
  # otherwise-valid bind.
  defp isa_violation_class({:object_link, _obj}, _term, _store, _branch), do: nil
  defp isa_violation_class({:isa_object_link, _obj}, _term, _store, _branch), do: nil

  # An isa entry that's still an open var (`class(x, y)` with both sides
  # open posts `y` onto `x` this way) hasn't resolved to a class yet, so it
  # can't be violated one way or the other -- same posture `dif` already
  # takes toward a still-open counterpart. Deref first in case it resolved
  # in the meantime some other way (e.g. `y` bound directly, independent of
  # `x`), only a genuinely resolved entry gets the real membership check.
  # Returns the *resolved* class (not the raw, possibly-var entry) so a
  # reported violation names the actual class, not the link var.
  defp isa_violation_class(raw_class, term, store, branch) do
    class = deref(store, raw_class)
    if not var?(class) and not isa?(term, class, branch), do: class
  end

  # `:number`/`:list`/`:map`/`:string` are decidable from `term`'s own shape —
  # no lookup. A value class beyond those four is provable by matching one of
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
  defp isa?(term, class, branch), do: AL.Dispatch.instance_of?(term, class, branch)

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
  def occurs?(var, term, store), do: scan(var, term, store) == :occurs

  defp scan(_var, term, _store) when is_number(term) or is_binary(term), do: :ground
  defp scan(var, {:"$fresh", _, _} = term, store), do: scan_var(var, term, store)

  defp scan(var, {:"$var", _name} = term, store), do: scan_var(var, term, store)

  defp scan(var, term, store) when is_list(term), do: scan_list(var, term, store, :ground)

  defp scan(var, term, store) when is_tuple(term),
    do: scan_list(var, Tuple.to_list(term), store, :ground)

  defp scan(var, term, store) when is_map(term),
    do: scan_list(var, Map.keys(term) ++ Map.values(term), store, :ground)

  defp scan(_var, _term, _store), do: :ground

  defp scan_var(var, term, store) do
    if ground_marked?(store, term) do
      :ground
    else
      case deref(store, term) do
        ^var -> :occurs
        resolved -> if var?(resolved), do: :open, else: scan(var, resolved, store)
      end
    end
  end

  defp scan_list(var, [head | tail], store, acc) when is_integer(head),
    do: scan_list(var, tail, store, acc)

  defp scan_list(var, [head | tail], store, acc) do
    case scan(var, head, store) do
      :occurs -> :occurs
      found -> scan_list(var, tail, store, both(acc, found))
    end
  end

  defp scan_list(_var, [], _store, acc), do: acc

  defp scan_list(var, tail, store, acc) do
    case scan(var, tail, store) do
      :occurs -> :occurs
      found -> both(acc, found)
    end
  end

  defp both(:ground, :ground), do: :ground
  defp both(_left, _right), do: :open

  @spec unify(t(), t(), store(), AL.Branch.t()) :: store() | nil
  def unify(x, y, store \\ %{}, branch \\ AL.Branch.head()),
    do: AL.Var.Unification.unify(x, y, store, branch, :opaque)

  @spec unify_value(t(), t(), store(), AL.Branch.t()) :: store() | nil
  def unify_value(x, y, store, branch), do: AL.Var.Unification.unify(x, y, store, branch, :value)

  @spec unify_structural(t(), t(), store(), AL.Branch.t()) :: store() | nil
  def unify_structural(x, y, store, branch),
    do: AL.Var.Unification.unify(x, y, store, branch, :opaque)

  @spec subst(t(), store()) :: t()
  def subst(term, store), do: subst(term, store, & &1)

  # `rewrite_unbound` lets a caller rename a var that's still unbound after
  # dereferencing (e.g. AL.eval's display layer, which maps an internal freshened
  # var back to whichever observable query var it's aliased to) instead of
  # showing it as-is.
  @spec subst(t(), store(), (variable() -> t())) :: t()
  def subst(term, store, rewrite_unbound) do
    case subst_walk(term, store, rewrite_unbound) do
      :same -> term
      {:new, new} -> new
    end
  end

  defp subst_walk(term, _store, _rewrite)
       when is_number(term) or is_binary(term) or term == [],
       do: :same

  defp subst_walk({:"$fresh", _base, _scope} = leaf, store, rewrite),
    do: changed(leaf, subst_leaf(leaf, store, rewrite))

  defp subst_walk({:"$var", _name} = term, store, rewrite),
    do: changed(term, subst_leaf(term, store, rewrite))

  defp subst_walk([head | tail], store, rewrite) when is_integer(head) do
    case subst_walk(tail, store, rewrite) do
      :same -> :same
      {:new, new_tail} -> {:new, [head | new_tail]}
    end
  end

  defp subst_walk([head | tail], store, rewrite) do
    case {subst_walk(head, store, rewrite), subst_walk(tail, store, rewrite)} do
      {:same, :same} -> :same
      {new_head, new_tail} -> {:new, [kept(head, new_head) | kept(tail, new_tail)]}
    end
  end

  defp subst_walk(term, store, rewrite) when is_struct(term) do
    :maps.fold(
      fn
        :__struct__, _value, acc ->
          acc

        key, value, acc ->
          case subst_walk(value, store, rewrite) do
            :same -> acc
            {:new, new} -> {:new, Map.put(kept(term, acc), key, new)}
          end
      end,
      :same,
      term
    )
  end

  defp subst_walk(term, store, rewrite) when is_map(term) do
    subst_walk_map(:maps.iterator(term), term, store, rewrite, 0)
  end

  defp subst_walk(term, store, rewrite) when is_tuple(term) do
    case subst_walk(Tuple.to_list(term), store, rewrite) do
      :same -> :same
      {:new, elements} -> {:new, List.to_tuple(elements)}
    end
  end

  defp subst_walk(_term, _store, _rewrite), do: :same

  defp subst_walk_map(iterator, original, store, rewrite, count) do
    case :maps.next(iterator) do
      :none ->
        :same

      {key, value, rest} ->
        new_key = subst_walk(key, store, rewrite)
        new_value = subst_walk(value, store, rewrite)

        if new_key == :same and new_value == :same do
          subst_walk_map(rest, original, store, rewrite, count + 1)
        else
          prefix = original |> Enum.take(count) |> Map.new()
          updated = Map.put(prefix, kept(key, new_key), kept(value, new_value))
          {:new, subst_walk_map_rest(rest, updated, store, rewrite)}
        end
    end
  end

  defp subst_walk_map_rest(iterator, updated, store, rewrite) do
    case :maps.next(iterator) do
      :none ->
        updated

      {key, value, rest} ->
        new_key = kept(key, subst_walk(key, store, rewrite))
        new_value = kept(value, subst_walk(value, store, rewrite))
        subst_walk_map_rest(rest, Map.put(updated, new_key, new_value), store, rewrite)
    end
  end

  defp changed(leaf, leaf), do: :same
  defp changed(_leaf, new), do: {:new, new}

  defp kept(term, :same), do: term
  defp kept(_term, {:new, new}), do: new

  @spec copy_term_with_constraints(t(), store()) :: {t(), store()}
  def copy_term_with_constraints(term, store) do
    resolved = subst(term, store)
    variables = reachable_constraint_variables(resolved, store)

    renaming =
      variables
      |> Enum.sort()
      |> Map.new(fn variable ->
        {variable, fresh({:"$var", "_G"}, Integer.to_string(AL.fresh_scope()))}
      end)

    rewrite = fn variable -> Map.get(renaming, variable, variable) end
    copied_term = subst(resolved, %{}, rewrite)

    copied_constraints =
      Enum.reduce(variables, %{}, fn variable, acc ->
        case constraint_set(store, variable) do
          %ConstraintSet{} = set ->
            Map.put(acc, Map.fetch!(renaming, variable), subst(set, store, rewrite))

          nil ->
            acc
        end
      end)

    {copied_term, copied_constraints}
  end

  defp reachable_constraint_variables(term, store) do
    term
    |> find_vars()
    |> MapSet.delete({:"$var", "_"})
    |> MapSet.to_list()
    |> collect_constraint_variables(store, MapSet.new())
  end

  defp collect_constraint_variables([], _store, seen), do: MapSet.to_list(seen)

  defp collect_constraint_variables([variable | rest], store, seen) do
    variable = deref(store, variable)

    cond do
      not var?(variable) or variable == {:"$var", "_"} or MapSet.member?(seen, variable) ->
        collect_constraint_variables(rest, store, seen)

      true ->
        related =
          case constraint_set(store, variable) do
            %ConstraintSet{} = set ->
              set
              |> subst(store)
              |> find_vars()
              |> MapSet.delete({:"$var", "_"})
              |> MapSet.to_list()

            nil ->
              []
          end

        collect_constraint_variables(rest ++ related, store, MapSet.put(seen, variable))
    end
  end

  # A bound var derefs to its term, which is itself substituted
  defp subst_leaf({:"$fresh", _base, _scope} = leaf, store, rewrite_unbound) do
    case deref(store, leaf) do
      ^leaf ->
        rewrite_unbound.(leaf)

      other ->
        if var?(other), do: rewrite_unbound.(other), else: subst(other, store, rewrite_unbound)
    end
  end

  defp subst_leaf({:"$var", _name} = leaf, store, rewrite_unbound) do
    case deref(store, leaf) do
      ^leaf ->
        rewrite_unbound.(leaf)

      other ->
        if var?(other), do: rewrite_unbound.(other), else: subst(other, store, rewrite_unbound)
    end
  end

  @spec find_vars(t()) :: MapSet.t(variable())
  @spec find_vars(t(), MapSet.t(variable())) :: MapSet.t(variable())
  def find_vars(term), do: find_vars(term, MapSet.new())

  def find_vars(term, acc) do
    AL.Term.reduce(term, acc, fn leaf, s -> if var?(leaf), do: MapSet.put(s, leaf), else: s end)
  end

  # Wrapping rather than minting keeps the atom table flat; a
  # re-freshened var nests, so distinct scopes stay distinct.
  @spec freshen(t(), String.t()) :: t()
  def freshen(term, f) do
    AL.Term.map(term, fn
      {:"$var", "_"} -> {:"$var", "_"}
      {:"$fresh", _base, _scope} = leaf -> fresh(leaf, f)
      leaf -> if var?(leaf), do: fresh(leaf, f), else: leaf
    end)
  end

  @spec freshen(t(), String.t(), MapSet.t(variable())) :: t()
  def freshen(term, f, only) do
    AL.Term.map(term, fn
      {:"$var", "_"} -> {:"$var", "_"}
      leaf -> if MapSet.member?(only, leaf), do: fresh(leaf, f), else: leaf
    end)
  end
end
