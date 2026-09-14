defmodule Examples.ALSlotHistory do
  @moduledoc """
  I provide examples for `slot_history` -- every value a durable object's
  slot has been bound to, oldest first. Backed by `AL.Object`'s `slots` bag
  carrying `tx_from`/`tx_to` per whole-map version (see its `@relations`
  doc) -- no separate history table, retract/set never delete a row, they
  close it.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example slot_history_finds_every_value_a_slot_has_held() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        defclass :history_probe, super: :object, ivars: [count: []] do
        end

        new(:history_probe, obj)
        set_slot(obj, :count, 1)
        set_slot(obj, :count, 2)
        set_slot(obj, :count, 3)
        slot_history(obj, :count, values)
      end

    assert Map.get(bindings, :"$values") == [1, 2, 3]
    :ok
  end

  # A `slots` row versions the *whole* map, not one row per key -- writing
  # `:other` twice creates two more whole-map versions even though `:count`
  # never changed. `slot_history` still reports `:count`'s own history as a
  # single value, not three repeats -- the collapsing (`dedupe`, bootstrap.ex)
  # is what makes that true, not an accident of how few writes happened.
  example slot_history_collapses_repeats_from_unrelated_key_changes() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        defclass :history_probe_unrelated, super: :object, ivars: [count: [], other: []] do
        end

        new(:history_probe_unrelated, obj)
        set_slot(obj, :count, 1)
        set_slot(obj, :other, :a)
        set_slot(obj, :other, :b)
        slot_history(obj, :count, values)
      end

    assert Map.get(bindings, :"$values") == [1]
    :ok
  end

  # `vm_slot_at`'s ground-`t` leg is interval containment (`AL.Var.in_bounds?`),
  # not equality against a row's own `tx_from` -- querying for `2` at exactly
  # the instant it became true has to succeed, proving the half-open
  # `[tx_from, tx_to)` -> closed-inclusive `tx_to - 1` conversion lands on
  # the *new* row at the boundary instant, not the one it closed. `t1`'s own
  # `[tx_from, tx_to)` collapses to a single instant here (nothing else runs
  # between the two writes) -- `vm_label` grounds it from its posted bounds,
  # then `t1 + 1` is exactly the boundary instant, no `findall` round-trip
  # needed to get there (routing a still-open, bounds-only var through
  # `findall`'s own collection is a separate, known-fragile thing to lean
  # on -- see `slot_at_open_time_posts_a_real_upper_bound`, below, which
  # avoids it entirely instead).
  example slot_at_ground_time_finds_the_value_in_effect_at_the_boundary() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        defclass :clp_boundary_probe, super: :object, ivars: [count: []] do
        end

        new(:clp_boundary_probe, obj)
        set_slot(obj, :count, 1)
        set_slot(obj, :count, 2)

        vm_slot_at(obj, :count, 1, t1)
        label(t1)
        is(boundary, t1 + 1)
        vm_slot_at(obj, :count, v_at_boundary, boundary)
      end

    assert Map.get(bindings, :"$v_at_boundary") == 2
    :ok
  end

  # The real point of building this on `AL.Var.add_bounds` instead of just
  # filtering: an open `t` isn't inert data handed back for inspection, it's
  # a genuinely narrowed, still-open CLP var that composes with whatever
  # else constrains it in the same query -- including ordinary comparison
  # goals against *another* open, bounds-carrying var from a second
  # `vm_slot_at` call, nothing about this feature had to teach anything
  # special to. `1`'s interval is strictly before `2`'s (it closes exactly
  # when `2` opens), so `t >= t2` must fail -- not because of anything this
  # example does, but because `AL.Var.Bounds`'s own `add_compare` sees the
  # bounds each `vm_slot_at` call already posted and finds them infeasible
  # together, same as it would for any other two already-bounded vars.
  example slot_at_open_time_posts_a_real_upper_bound() do
    result =
      run branch: :examples do
        defclass :clp_upper_bound_probe, super: :object, ivars: [count: []] do
        end

        new(:clp_upper_bound_probe, obj)
        set_slot(obj, :count, 1)
        set_slot(obj, :count, 2)

        vm_slot_at(obj, :count, 1, t)
        vm_slot_at(obj, :count, 2, t2)
        t >= t2
      end

    assert {:aborted, _} = result
    :ok
  end
end
