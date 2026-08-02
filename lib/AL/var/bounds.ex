defmodule AL.Var.Bounds do
  @moduledoc """
  Narrows a still-open var's `{lo, hi}` interval from `< > <= >=`, via a
  worklist fixpoint over propagators on `AL.Var.ConstraintSet` (same slot
  `dif`/`isa` use). A side may be a bare var/number or an affine `+ - *`
  expression with one ground operand (`x + 1`); narrowing inverts back onto
  the var. `/ ** rem` unsupported — hard-fails.
  """

  alias AL.Var.ConstraintSet

  @type affine() :: {:const, number()} | {:linear, AL.Var.variable(), number(), number()}
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

  # Reduces a (already-substituted) comparison operand to `{:const, n}` or
  # `{:linear, var, coeff, const}` ("value = coeff * var + const"). Only
  # `+ - *` combine two affine forms into one; anything else (non-numeric
  # ground atom, `/ ** rem`, two distinct vars multiplied) is `:error`.
  defp affine(_store, n) when is_number(n), do: {:ok, {:const, n}}

  defp affine(store, %AL.Goal.OApply{method_id: op, args: [l, r]}) when op in [:+, :-, :*] do
    with {:ok, al} <- affine(store, l), {:ok, ar} <- affine(store, r) do
      combine(op, al, ar)
    end
  end

  defp affine(store, term) do
    case AL.Var.deref(store, term) do
      n when is_number(n) -> {:ok, {:const, n}}
      v -> if AL.Var.var?(v), do: {:ok, {:linear, v, 1, 0}}, else: :error
    end
  end

  defp combine(:+, {:const, a}, {:const, b}), do: {:ok, {:const, a + b}}
  defp combine(:+, {:const, c}, {:linear, v, coeff, k}), do: {:ok, mk_linear(v, coeff, k + c)}
  defp combine(:+, {:linear, v, coeff, k}, {:const, c}), do: {:ok, mk_linear(v, coeff, k + c)}

  defp combine(:+, {:linear, v, c1, k1}, {:linear, v, c2, k2}),
    do: {:ok, mk_linear(v, c1 + c2, k1 + k2)}

  defp combine(:+, {:linear, _, _, _}, {:linear, _, _, _}), do: :error

  defp combine(:-, {:const, a}, {:const, b}), do: {:ok, {:const, a - b}}
  defp combine(:-, {:linear, v, coeff, k}, {:const, c}), do: {:ok, mk_linear(v, coeff, k - c)}
  defp combine(:-, {:const, c}, {:linear, v, coeff, k}), do: {:ok, mk_linear(v, -coeff, c - k)}

  defp combine(:-, {:linear, v, c1, k1}, {:linear, v, c2, k2}),
    do: {:ok, mk_linear(v, c1 - c2, k1 - k2)}

  defp combine(:-, {:linear, _, _, _}, {:linear, _, _, _}), do: :error

  defp combine(:*, {:const, a}, {:const, b}), do: {:ok, {:const, a * b}}
  defp combine(:*, {:const, c}, {:linear, v, coeff, k}), do: {:ok, mk_linear(v, coeff * c, k * c)}
  defp combine(:*, {:linear, v, coeff, k}, {:const, c}), do: {:ok, mk_linear(v, coeff * c, k * c)}
  defp combine(:*, {:linear, _, _, _}, {:linear, _, _, _}), do: :error

  defp mk_linear(_v, 0, k), do: {:const, k}
  defp mk_linear(v, c, k), do: {:linear, v, c, k}

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

  defp affine_vars({:linear, v, _coeff, _const}), do: [v]
  defp affine_vars({:const, _}), do: []

  defp run_fixpoint(store, worklist, branch) do
    case Enum.at(worklist, 0) do
      nil ->
        store

      {lo_aff, hi_aff, strict} = t ->
        rest = MapSet.delete(worklist, t)

        case narrow_pair(store, lo_aff, hi_aff, strict, branch) do
          nil -> nil
          {new_store, more} -> run_fixpoint(new_store, MapSet.union(rest, more), branch)
        end
    end
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

  # An affine form's own domain: a constant's is itself; a `coeff * var +
  # const` scales the var's domain (`raw_domain/2`) and, for a negative
  # coefficient, swaps ends (multiplying by a negative reverses order).
  defp domain_of(_store, {:const, n}), do: {n, n}
  defp domain_of(store, {:linear, v, coeff, k}), do: scale_domain(raw_domain(store, v), coeff, k)

  defp scale_domain({lo, hi}, coeff, k) when coeff >= 0,
    do: {scale(lo, coeff, k), scale(hi, coeff, k)}

  defp scale_domain({lo, hi}, coeff, k), do: {scale(hi, coeff, k), scale(lo, coeff, k)}

  defp scale(nil, _coeff, _k), do: nil
  defp scale(n, coeff, k), do: n * coeff + k

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
  # (`new_lo > new_hi`); the `:linear` branch has a second one after
  # inverting back onto the var, since integer rounding can turn an
  # otherwise-feasible real range infeasible (e.g. `2 * v` narrowed to
  # `[3, 3]` has no integer `v`, even though `3 <= 3`).
  defp apply_domain(store, aff, {new_lo, new_hi}, branch) do
    if new_lo != nil and new_hi != nil and new_lo > new_hi do
      :fail
    else
      apply_domain_ok(store, aff, {new_lo, new_hi}, branch)
    end
  end

  defp apply_domain_ok(store, {:const, n}, {new_lo, new_hi}, _branch) do
    if AL.Var.in_bounds?({new_lo, new_hi}, n), do: {:ok, store, []}, else: :fail
  end

  defp apply_domain_ok(store, {:linear, v, coeff, k}, {new_lo, new_hi}, branch) do
    {v_lo, v_hi} = invert_domain({new_lo, new_hi}, coeff, k)

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
