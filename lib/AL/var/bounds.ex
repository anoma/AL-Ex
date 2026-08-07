defmodule AL.Var.Bounds do
  @moduledoc """
  Narrows a still-open var's `{lo, hi}` interval from `< > <= >= eq`
  (`eq` = CLP(FD) `#=`, spelled `eq/2` at the surface — `#` can't appear in
  Elixir source), via a worklist fixpoint over propagators on
  `AL.Var.ConstraintSet` (same slot `dif`/`isa` use). A side reduces to
  `Σ(coeff·var) + const` — real N-ary bounds consistency (each variable's
  bounds narrow from the *others'* current bounds via interval
  add/subtract, not just a single-variable inversion), so any number of
  still-open vars combined by `+`/`-` narrow/auto-bind together. `*` only
  combines when at least one side is a ground scalar (scaling a sum) —
  genuine interval multiplication of two still-open vars is a real,
  separate propagator this doesn't implement (sign-dependent corner
  products, division by a zero-spanning interval on the inverse side —
  not representable in the same flat sum structure). `/ ** rem`
  unsupported too — all three hard-fail.
  """

  alias AL.Var.ConstraintSet

  @type affine() :: {:sum, %{AL.Var.variable() => number()}, number()}
  @type propagator() :: {affine(), affine(), boolean()}

  # Read side Goal.Label uses. Ground term = singleton domain.
  @spec bounds_of(AL.Var.store(), AL.Var.t()) :: {ConstraintSet.bound(), ConstraintSet.bound()}
  def bounds_of(store, term), do: raw_domain(store, term)

  # Each side -> affine form -> propagator on every var it mentions -> a
  # worklist fixpoint (narrowing one var re-queues others parked on it, so
  # `x < y, y < 5` tightens x transitively). Collapse to a single value ->
  # bind via AL.Var.bind/4 (so dif/isa still gets checked). nil = infeasible
  # or non-affine side — same backtrack either way at the call site.
  @spec add_compare(AL.Var.store(), atom(), AL.Var.t(), AL.Var.t(), AL.Branch.t()) ::
          AL.Var.store() | nil
  def add_compare(store, :eq, a, b, branch) do
    with {:ok, a_aff} <- affine(store, a), {:ok, b_aff} <- affine(store, b) do
      # `a = b` as two simultaneous `<=` propagators (a<=b and b<=a), on the
      # same worklist fixpoint `< > <= >=` already use — narrowing one side
      # re-triggers the other, so a fully-determined side collapses the
      # other to a singleton and auto-binds it (AL.Var.bind, in
      # apply_domain_ok), the same way `#=` narrows/grounds in CLP(FD).
      store
      |> register_propagator(a_aff, b_aff, false)
      |> register_propagator(b_aff, a_aff, false)
      |> run_fixpoint(MapSet.new([{a_aff, b_aff, false}, {b_aff, a_aff, false}]), branch)
    else
      :error -> nil
    end
  end

  def add_compare(store, op, a, b, branch) do
    {lo_expr, hi_expr, strict} = normalize(op, a, b)

    with {:ok, lo_aff} <- affine(store, lo_expr),
         {:ok, hi_aff} <- affine(store, hi_expr) do
      store
      |> register_propagator(lo_aff, hi_aff, strict)
      |> run_fixpoint(MapSet.new([{lo_aff, hi_aff, strict}]), branch)
    else
      :error -> nil
    end
  end

  defp normalize(:<, a, b), do: {a, b, true}
  defp normalize(:<=, a, b), do: {a, b, false}
  defp normalize(:>, a, b), do: {b, a, true}
  defp normalize(:>=, a, b), do: {b, a, false}

  # Reduces a (already-substituted) comparison operand to `{:sum, coeffs,
  # const}` — "Σ(coeff·var) + const", coeffs empty = a plain constant. Only
  # `+ - *` combine two affine forms into one; anything else (non-numeric
  # ground atom, `/ ** rem`, two distinct open vars multiplied) is `:error`.
  defp affine(_store, n) when is_number(n), do: {:ok, {:sum, %{}, n}}

  defp affine(store, %AL.Goal.OApply{method_id: op, args: [l, r]}) when op in [:+, :-, :*] do
    with {:ok, al} <- affine(store, l), {:ok, ar} <- affine(store, r) do
      combine(op, al, ar)
    end
  end

  defp affine(store, term) do
    case AL.Var.deref(store, term) do
      n when is_number(n) -> {:ok, {:sum, %{}, n}}
      v -> if AL.Var.var?(v), do: {:ok, {:sum, %{v => 1}, 0}}, else: :error
    end
  end

  # `+`/`-` merge coefficient maps term-by-term (same var on both sides
  # cancels or combines, not an error) — this is what lets an arbitrary
  # number of still-open vars share one sum. `*` only combines when one
  # side is a ground scalar (empty coeffs map): scaling a sum is still
  # linear. Two non-scalar sides is a genuine product of unknowns —
  # unsupported (see moduledoc).
  defp combine(:+, {:sum, c1, k1}, {:sum, c2, k2}),
    do: {:ok, {:sum, merge_coeffs(c1, c2, 1), k1 + k2}}

  defp combine(:-, {:sum, c1, k1}, {:sum, c2, k2}),
    do: {:ok, {:sum, merge_coeffs(c1, c2, -1), k1 - k2}}

  defp combine(:*, {:sum, c1, k1}, {:sum, c2, k2}) do
    cond do
      map_size(c1) == 0 -> {:ok, scale_sum(c2, k2, k1)}
      map_size(c2) == 0 -> {:ok, scale_sum(c1, k1, k2)}
      true -> :error
    end
  end

  defp merge_coeffs(c1, c2, sign) do
    c2
    |> Enum.reduce(c1, fn {v, c}, acc -> Map.update(acc, v, sign * c, &(&1 + sign * c)) end)
    |> drop_zero_coeffs()
  end

  defp scale_sum(coeffs, const, scalar),
    do:
      {:sum, coeffs |> Map.new(fn {v, c} -> {v, c * scalar} end) |> drop_zero_coeffs(),
       const * scalar}

  defp drop_zero_coeffs(coeffs), do: coeffs |> Enum.reject(fn {_v, c} -> c == 0 end) |> Map.new()

  defp affine_vars({:sum, coeffs, _const}), do: Map.keys(coeffs)

  defp register_propagator(store, lo_aff, hi_aff, strict) do
    prop = {lo_aff, hi_aff, strict}

    (affine_vars(lo_aff) ++ affine_vars(hi_aff))
    |> Enum.uniq()
    |> Enum.reduce(store, fn v, acc ->
      Map.update(acc, v, %ConstraintSet{props: [prop]}, fn
        %ConstraintSet{} = set -> %{set | props: [prop | set.props]}
        other -> other
      end)
    end)
  end

  # `def`, not `defp` — `AL.Var.bind/4` also runs the fixpoint directly, over
  # whatever propagators are already parked on a var at the moment an
  # *ordinary* unify grounds it (not just when a fresh `eq`/compare call
  # touches it) — otherwise a var bound via plain head unification (e.g. a
  # recursive clause's own base case) would leave stale propagators
  # unchecked until something else happened to touch it later.
  @spec run_fixpoint(
          AL.Var.store(),
          MapSet.t(propagator() | either_propagator() | AL.Var.AllDif.propagator()),
          AL.Branch.t()
        ) :: AL.Var.store() | nil
  def run_fixpoint(store, worklist, branch) do
    case Enum.at(worklist, 0) do
      nil ->
        store

      {:either, left, right} = t ->
        rest = MapSet.delete(worklist, t)

        case resolve_either(store, left, right, branch) do
          nil -> nil
          {new_store, more} -> run_fixpoint(new_store, MapSet.union(rest, more), branch)
        end

      {:all_dif, vars} = t ->
        rest = MapSet.delete(worklist, t)

        case AL.Var.AllDif.resolve(store, vars, branch) do
          nil -> nil
          {new_store, more} -> run_fixpoint(new_store, MapSet.union(rest, more), branch)
        end

      {lo_aff, hi_aff, strict} = t ->
        rest = MapSet.delete(worklist, t)

        case narrow_pair(store, lo_aff, hi_aff, strict, branch) do
          nil -> nil
          {new_store, more} -> run_fixpoint(new_store, MapSet.union(rest, more), branch)
        end
    end
  end

  # `either({op1, a1, b1}, {op2, a2, b2})` — CLP(FD) `#\/`: the constraint
  # that *at least one* side holds, kept and propagated directly (no
  # reified boolean, no separate `#/\`-composition layer) — parked on
  # every var either side mentions, same `props`/worklist mechanism `eq`/
  # `< > <= >=` already use, so it's re-checked whenever any of them
  # narrow (label included, since a bind re-triggers `props` the same way
  # any other propagator does). Only ever resolves by *elimination*: once
  # one side is provably infeasible (`add_compare` on it returns `nil`),
  # the constraint collapses to "the other side must hold," and that side
  # gets applied for real (a genuine commit, not just a check). Neither
  # side provably dead yet -> stays parked, undetermined either way. Both
  # dead -> the whole disjunction fails.
  @type either_propagator() :: {:either, compare_triple(), compare_triple()}
  @typep compare_triple() :: {atom(), AL.Var.t(), AL.Var.t()}

  @spec either(AL.Var.store(), compare_triple(), compare_triple(), AL.Branch.t()) ::
          AL.Var.store() | nil
  def either(store, left, right, branch) do
    prop = {:either, left, right}
    vars = either_vars(left, right)

    store
    |> register_either_propagator(vars, prop)
    |> run_fixpoint(MapSet.new([prop]), branch)
  end

  defp either_vars({_op1, a1, b1}, {_op2, a2, b2}),
    do: [a1, b1, a2, b2] |> Enum.flat_map(&AL.Var.find_vars/1) |> Enum.uniq()

  # `either_vars` returns the *original* atoms captured when `:either` was
  # posted (a pure syntactic scan, no store involved) -- but once one of
  # them (`candidate`, say) gets aliased forward through an unrelated
  # unification (e.g. `between`'s recursive dispatch aliasing it to a fresh
  # var at every recursion level), the *live* `ConstraintSet` actually
  # carrying this propagator's `props` entry migrates with it
  # (`AL.Var.migrate_constraints`) -- so the original atom's own store slot
  # is just a stale alias pointer, not a `ConstraintSet` anymore.
  # `strip_either_prop` keyed on the unresolved atoms silently no-ops on
  # that stale slot and never reaches the var that actually holds the
  # propagator now, so the "probe" a speculative narrowing runs against
  # still carries it live -- a bind inside that narrowing re-triggers this
  # exact propagator, recursing into itself. Following each var through
  # `AL.Var.deref` first finds today's actual representative before
  # stripping.
  defp either_vars_live(store, left, right),
    do: either_vars(left, right) |> Enum.map(&AL.Var.deref(store, &1)) |> Enum.uniq()

  defp register_either_propagator(store, vars, prop) do
    Enum.reduce(vars, store, fn v, acc ->
      Map.update(acc, v, %ConstraintSet{props: [prop]}, fn
        %ConstraintSet{} = set -> %{set | props: [prop | set.props]}
        other -> other
      end)
    end)
  end

  # Speculative: run each side's real narrowing (the exact same
  # `add_compare` a plain, unreified `eq`/`< > <= >=` call would run,
  # integer-consistency check included) on a probe copy with *this same*
  # `{:either, left, right}` propagator stripped from every var it's parked
  # on first -- otherwise a bind inside the speculative narrowing (e.g. one
  # side collapsing a var to a singleton) re-triggers this exact
  # propagator on the still-live copy, recursing into itself. Stripping
  # has to go through `either_vars_live/3` (deref each var first), not the
  # raw post-time atoms `either_vars/2` returns: once one of them (e.g. a
  # `label`'d var passed through a recursive method like `between`,
  # which re-aliases it to a fresh var at every recursion level) gets
  # aliased elsewhere, the *live* `ConstraintSet` holding this propagator
  # migrates with it (`AL.Var.migrate_constraints`) -- the original atom's
  # own store slot is left as a stale alias pointer. Stripping by the
  # unresolved atom silently no-ops on that stale slot, leaves the
  # propagator live on the probe under its new address, and a bind inside
  # the "speculative" narrowing re-enters this exact function -- which is
  # genuinely reentrant (not just slow) since each reentry can again bind
  # the shared var and trigger another.
  defp resolve_either(store, {op1, a1, b1} = left, {op2, a2, b2} = right, branch) do
    probe = strip_either_prop(store, either_vars_live(store, left, right), {:either, left, right})
    left_result = add_compare(probe, op1, a1, b1, branch)
    right_result = add_compare(probe, op2, a2, b2, branch)

    case {left_result, right_result} do
      {nil, nil} ->
        nil

      {nil, r} ->
        {r, MapSet.new()}

      {l, nil} ->
        {l, MapSet.new()}

      {_, _} ->
        # Both sides currently have a witness -- can't eliminate either one
        # yet. If the side each expression shares (`a1`/`a2`, e.g.
        # `candidate` in `eq(candidate, x*5) or eq(candidate, y*3)`) is
        # already ground, it can never narrow further in this branch, so
        # re-checking later will always reach this exact "both survive"
        # answer again -- discharge for good (`probe`, propagator already
        # stripped) instead of re-parking on `store` and paying full
        # re-resolution on every future touch of a var either side
        # mentions. If `a1`/`a2` can still change, stay reactive.
        if AL.Var.var?(AL.Var.deref(store, a1)) or AL.Var.var?(AL.Var.deref(store, a2)) do
          {store, MapSet.new()}
        else
          {probe, MapSet.new()}
        end
    end
  end

  defp strip_either_prop(store, vars, prop) do
    Enum.reduce(vars, store, fn v, acc ->
      Map.update(acc, v, %ConstraintSet{}, fn
        %ConstraintSet{} = set -> %{set | props: List.delete(set.props, prop)}
        other -> other
      end)
    end)
  end

  # `lo <= hi` (or `lo < hi` if `strict`): narrow `hi`'s floor from `lo`'s
  # floor, and `lo`'s ceiling from `hi`'s ceiling — the two directions an
  # order constraint propagates in an interval domain.
  defp narrow_pair(store, lo_aff, hi_aff, strict, branch) do
    {lo_lo, lo_hi} = domain_of(store, lo_aff)
    {hi_lo, hi_hi} = domain_of(store, hi_aff)

    new_hi_bounds = {AL.Var.tighten_max(hi_lo, bump_up(lo_lo, strict)), hi_hi}
    new_lo_bounds = {lo_lo, AL.Var.tighten_min(lo_hi, bump_down(hi_hi, strict))}

    with {:ok, store1, hi_props} <- apply_domain(store, hi_aff, new_hi_bounds, branch),
         {:ok, store2, lo_props} <- apply_domain(store1, lo_aff, new_lo_bounds, branch) do
      {store2, MapSet.new(hi_props ++ lo_props)}
    else
      :fail -> nil
    end
  end

  # A sum's own domain: interval-add every term's own (var domain * coeff),
  # plus const. Each term is still one-var-linear (`scale_domain`); it's the
  # accumulation across terms, not any single term, that's N-ary.
  defp domain_of(store, {:sum, coeffs, const}) do
    Enum.reduce(coeffs, {const, const}, fn {v, coeff}, {acc_lo, acc_hi} ->
      {lo, hi} = scale_domain(raw_domain(store, v), coeff, 0)
      {add_bound(acc_lo, lo), add_bound(acc_hi, hi)}
    end)
  end

  # Every term's domain except `exclude`'s, for isolating one variable out
  # of a multi-var sum (bounds consistency: what must `exclude`'s own
  # domain be, given everyone else's *current* domain, for the whole sum to
  # land in the target interval).
  defp domain_of_others(store, coeffs, const, exclude) do
    Enum.reduce(coeffs, {const, const}, fn
      {^exclude, _coeff}, acc ->
        acc

      {v, coeff}, {acc_lo, acc_hi} ->
        {lo, hi} = scale_domain(raw_domain(store, v), coeff, 0)
        {add_bound(acc_lo, lo), add_bound(acc_hi, hi)}
    end)
  end

  defp scale_domain({lo, hi}, coeff, k) when coeff >= 0,
    do: {scale(lo, coeff, k), scale(hi, coeff, k)}

  defp scale_domain({lo, hi}, coeff, k), do: {scale(hi, coeff, k), scale(lo, coeff, k)}

  defp scale(nil, _coeff, _k), do: nil
  defp scale(n, coeff, k), do: n * coeff + k

  defp add_bound(nil, _), do: nil
  defp add_bound(_, nil), do: nil
  defp add_bound(a, b), do: a + b

  # Interval subtraction: [a,b] - [c,d] = [a-d, b-c] (the ends that widen the
  # result the least/most swap, same reasoning as `scale_domain`'s
  # negative-coefficient case).
  defp subtract_bounds({t_lo, t_hi}, {o_lo, o_hi}),
    do: {sub_bound(t_lo, o_hi), sub_bound(t_hi, o_lo)}

  defp sub_bound(nil, _), do: nil
  defp sub_bound(_, nil), do: nil
  defp sub_bound(a, b), do: a - b

  # A bare var/number's own domain — ground terms are a singleton, an open
  # var reads its `ConstraintSet.bounds`, absent entirely means unbounded.
  defp raw_domain(store, term) do
    case AL.Var.deref(store, term) do
      n when is_number(n) ->
        {n, n}

      v ->
        case AL.Var.constraint_set(store, v) do
          %ConstraintSet{bounds: b} -> b
          _ -> {nil, nil}
        end
    end
  end

  # Applies a freshly-narrowed `{lo, hi}` to one side of a comparison. The
  # top-level infeasibility check is on the *expression's* own bounds
  # (`new_lo > new_hi`); each variable isolated out of it below has its own
  # second check, since integer rounding can turn an otherwise-feasible real
  # range infeasible (e.g. `2 * v` narrowed to `[3, 3]` has no integer `v`,
  # even though `3 <= 3`).
  defp apply_domain(store, aff, {new_lo, new_hi}, branch) do
    if new_lo != nil and new_hi != nil and new_lo > new_hi do
      :fail
    else
      apply_domain_ok(store, aff, {new_lo, new_hi}, branch)
    end
  end

  # No free vars: just a feasibility check against the constant. One free
  # var: isolate and invert directly. Several: bounds-consistency — narrow
  # each variable in turn from the target minus every *other* term's
  # current domain, re-narrowing (not re-deriving from scratch) as earlier
  # variables in the same pass update — full convergence across the whole
  # propagator, if it takes more than one pass, happens because a variable
  # that changed re-queues this same propagator (see `run_fixpoint`), not
  # because this single call loops internally.
  defp apply_domain_ok(store, {:sum, coeffs, const}, {new_lo, new_hi}, branch) do
    case Map.to_list(coeffs) do
      [] ->
        if AL.Var.in_bounds?({new_lo, new_hi}, const), do: {:ok, store, []}, else: :fail

      vars ->
        Enum.reduce_while(vars, {:ok, store, []}, fn {v, coeff}, {:ok, acc_store, acc_props} ->
          others = domain_of_others(acc_store, coeffs, const, v)
          term_bounds = subtract_bounds({new_lo, new_hi}, others)
          v_bounds = invert_domain(term_bounds, coeff, 0)

          case narrow_one_var(acc_store, v, v_bounds, branch) do
            :fail -> {:halt, :fail}
            {:ok, new_store, props} -> {:cont, {:ok, new_store, acc_props ++ props}}
          end
        end)
    end
  end

  defp narrow_one_var(store, v, {v_lo, v_hi}, branch) do
    if v_lo != nil and v_hi != nil and v_lo > v_hi do
      :fail
    else
      case AL.Var.deref(store, v) do
        n when is_number(n) ->
          if AL.Var.in_bounds?({v_lo, v_hi}, n), do: {:ok, store, []}, else: :fail

        dv ->
          old_bounds = raw_domain(store, dv)
          props = props_of(store, dv)

          cond do
            {v_lo, v_hi} == old_bounds ->
              {:ok, store, []}

            v_lo != nil and v_lo == v_hi ->
              case AL.Var.bind(store, dv, v_lo, branch) do
                nil -> :fail
                new_store -> {:ok, new_store, props}
              end

            true ->
              {:ok, set_bounds(store, dv, {v_lo, v_hi}), props}
          end
      end
    end
  end

  # Solves `coeff * v + k` in `[lo, hi]` for integer `v`, rounding each end
  # inward (ceil/floor) — the tightest sound bound, not just a conservative
  # one, since `v` can only ever land on multiples of `coeff` apart anyway.
  # Dividing by a negative coefficient flips which end maps to which.
  defp invert_domain({lo, hi}, coeff, k) when coeff > 0,
    do: {ceil_div(sub(lo, k), coeff), floor_div(sub(hi, k), coeff)}

  defp invert_domain({lo, hi}, coeff, k) when coeff < 0,
    do: {ceil_div(sub(hi, k), coeff), floor_div(sub(lo, k), coeff)}

  defp sub(nil, _k), do: nil
  defp sub(n, k), do: n - k

  defp floor_div(nil, _c), do: nil
  defp floor_div(n, c), do: Integer.floor_div(n, c)

  defp ceil_div(nil, _c), do: nil
  defp ceil_div(n, c), do: -Integer.floor_div(-n, c)

  defp props_of(store, v) do
    case AL.Var.constraint_set(store, v) do
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
end
