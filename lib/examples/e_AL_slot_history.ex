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

  example current_slots_match_history_after_retraction_fork_replay_and_abort() do
    parent = AL.Branch.fork(:tip, %AL.Branch{id: Examples.Support.branch()})

    inspect_slots = fn branch ->
      :mnesia.transaction(fn ->
        current = AL.Object.read_slots(:current_slots_probe, branch)
        history = AL.Object.scan_slots_history(:current_slots_probe, branch)
        open = for {:slots, object, _, :open, slots} <- history, do: {:slots, object, slots}
        assert current == open
        assert AL.Object.scan_slots(:current_slots_probe, :"$Slots", branch) == current
        {current, history}
      end)
    end

    try do
      {:atomic, _} =
        AL.eval_source(
          ~S"""
          vm_set_slot current_slots_probe count 1.
          vm_set_slot current_slots_probe other kept.
          vm_set_slot current_slots_probe count 2.
          vm_retract_slot current_slots_probe count.
          vm_retract_slot current_slots_probe other.
          not {slot current_slots_probe _ _}.
          vm_set_slot current_slots_probe count 3.
          vm_set_slot current_slots_probe count 3.
          """,
          parent
        )

      {:atomic, {current, history}} = inspect_slots.(parent)
      assert current == [{:slots, :current_slots_probe, %{count: 3}}]
      assert length(history) == 6
      assert length(Enum.uniq_by(history, &elem(&1, 2))) == 6

      for child <- [AL.Branch.fork(:tip, parent), AL.Branch.fork_stable(parent)] do
        try do
          assert {:atomic, {^current, ^history}} = inspect_slots.(child)

          assert {:aborted, _} =
                   AL.eval_source(
                     "vm_set_slot current_slots_probe count 999, fail.",
                     child
                   )

          assert {:atomic, {^current, ^history}} = inspect_slots.(child)
          {:atomic, _} = AL.eval_source("vm_set_slot current_slots_probe count 4.", child)
          {:atomic, {[{:slots, :current_slots_probe, %{count: 4}}], _}} = inspect_slots.(child)
          assert {:atomic, {^current, ^history}} = inspect_slots.(parent)
        after
          AL.Branch.discard(child)
        end
      end
    after
      AL.Branch.discard(parent)
    end
  end

  example slot_history_finds_every_value_a_slot_has_held() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @history_probe
        #{super => object, ivars => [#{name => count}]}.

        new history_probe Obj.
        set_slot Obj count 1.
        set_slot Obj count 2.
        set_slot Obj count 3.
        slot_history Obj count Values.
        """
      end

    assert Map.get(bindings, :"$Values") == [1, 2, 3]
    :ok
  end

  # A `slots` row versions the *whole* map, not one row per key -- writing
  # `:other` twice creates two more whole-map versions even though `:count`
  # never changed. `slot_history` still reports `:count`'s own history as a
  # single value, not three repeats -- the collapsing (`dedupe`, bootstrap.ex)
  # is what makes that true, not an accident of how few writes happened.
  example slot_history_collapses_repeats_from_unrelated_key_changes() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @history_probe_unrelated
        #{super => object, ivars => [#{name => count}, #{name => other}]}.

        new history_probe_unrelated Obj.
        set_slot Obj count 1.
        set_slot Obj other a.
        set_slot Obj other b.
        slot_history Obj count Values.
        """
      end

    assert Map.get(bindings, :"$Values") == [1]
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
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @clp_boundary_probe
        #{super => object, ivars => [#{name => count}]}.

        new clp_boundary_probe Obj.
        set_slot Obj count 1.
        set_slot Obj count 2.
        vm_slot_at Obj count 1 T1.
        label T1.
        = Boundary (+ T1 1).
        vm_slot_at Obj count VAtBoundary Boundary.
        """
      end

    assert Map.get(bindings, :"$VAtBoundary") == 2
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
      run branch: Examples.Support.branch() do
        ~AL"""
        @clp_upper_bound_probe
        #{super => object, ivars => [#{name => count}]}.

        new clp_upper_bound_probe Obj.
        set_slot Obj count 1.
        set_slot Obj count 2.
        vm_slot_at Obj count 1 T.
        vm_slot_at Obj count 2 T2.
        >= T T2.
        """
      end

    assert {:aborted, _} = result
    :ok
  end
end
