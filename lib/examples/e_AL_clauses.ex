defmodule Examples.ALClauses do
  @moduledoc """
  I pin the ordering contract of a method's clauses (its `oapply` rows): the
  order they're tried in, and that the order is stable across fork/replay and
  controllable by how clauses are (re)inserted.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  # A fresh class id per run so the persistent log can't accrete clauses across
  # runs and perturb the order under test.
  defp fresh_class do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower) |> String.to_atom()
  end

  @doc "A clause body read via `clause/n` must be executable structs: reflect reverse's recursive clause and run its body through `call`."
  example reflected_clause_body_executes() do
    {:atomic, {b, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        method list reverse M.
        clause M [[H . T], Out] Body.
        call [[H . T], Out] Body [[1, 2, 3], Result].
        """
      end

    assert Map.get(b, "$Result") == [3, 2, 1]
    b
  end

  # Two clauses that both match the same call, so `findall` reveals their order.
  example clauses_are_tried_in_definition_order() do
    c = fresh_class()

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_class ^c object.

        ^c >> tag
        | Self first |.

        ^c >> tag
        | Self second |.
        """
      end

    {:atomic, {b, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall T Ts (tag ^c T).
        """
      end

    assert Map.get(b, "$Ts") == [:first, :second]
    :ok
  end

  # A fork rebuilds its projection by replaying the log, so this also pins that
  # clause order survives replay/rehydrate.
  example clause_order_survives_fork() do
    # A dedicated throwaway branch, not `:examples` -- forking replays the
    # *entire* source branch's command history to materialize the new
    # branch's projection, and `:examples` accumulates writes from every
    # example in the suite, so forking from it directly scales with however
    # much the whole run has piled up by the time this happens to execute.
    # This example only needs a fork with the class visible, which a fresh
    # branch off `:main` gives just as well, for a fraction of the cost.
    base = AL.Branch.fork()
    c = fresh_class()

    {:atomic, _} =
      run branch: base.id do
        ~AL"""
        vm_set_class ^c object.

        ^c >> tag
        | Self first |.

        ^c >> tag
        | Self second |.
        """
      end

    tip = AL.Branch.fork(:tip, base)

    {:atomic, {b, _constraints, _}} =
      run branch: tip.id do
        ~AL"""
        findall T Ts (tag ^c T).
        """
      end

    assert Map.get(b, "$Ts") == [:first, :second]

    AL.Branch.discard(tip)
    AL.Branch.discard(base)
    :ok
  end

  # Retract all clauses and reinsert them in the opposite order; the new order
  # should be what's observed. This is the basis any reorder helper relies on.
  example clause_reinsertion_controls_order() do
    c = fresh_class()

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_class ^c object.

        ^c >> tag
        | Self first |.

        ^c >> tag
        | Self second |.
        """
      end

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        method ^c tag Id.
        vm_retract_oapply Id _.
        """
      end

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        method ^c tag Id.
        vm_set_oapply Id [Self, second] {}.
        vm_set_oapply Id [Self, first] {}.
        """
      end

    {:atomic, {b, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall T Ts (tag ^c T).
        """
      end

    assert Map.get(b, "$Ts") == [:second, :first]
    :ok
  end

  # `retract_oapply` closes a clause's row (`tx_to`) rather than deleting it
  # (`AL.Object.retract_oapply/4`, matching `retract_class`/`retract_super`/
  # `retract_method`'s existing pattern) -- `next_oapply_seq` counts past
  # closed rows too, same as it already does for class/super, so a clause
  # added after a retract gets a fresh, higher `seq`, never the retracted
  # one's. Under the old hard-delete behavior this would come back equal
  # (the deleted row's `seq` no longer counted at all), not greater.
  example a_retracted_clause_closes_rather_than_deletes_its_row() do
    c = fresh_class()

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_class ^c object.

        ^c >> tag
        | Self first |.
        """
      end

    {:atomic, {b, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        method ^c tag Id.
        clause Id SeqBefore [_Self, first] _.
        vm_retract_oapply Id [_Self, first].
        vm_set_oapply Id [Self, second] {}.
        clause Id SeqAfter [_Self, second] _.
        """
      end

    assert Map.get(b, "$SeqAfter") > Map.get(b, "$SeqBefore")
    :ok
  end

  # `clause/4` surfaces each clause's `seq`, so a reorder can read current
  # positions before deciding new ones.
  example clause_exposes_seq() do
    c = fresh_class()

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_class ^c object.

        ^c >> tag
        | Self first |.

        ^c >> tag
        | Self second |.
        """
      end

    {:atomic, {b, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        method ^c tag Id.
        findall S Seqs (clause Id S H Body).
        """
      end

    assert Map.get(b, "$Seqs") == [0, 1]
    :ok
  end

  # `set_oapply/4` places a clause at an explicit `seq`, so order follows the
  # seq you assign rather than insertion order: insert :first then :second but
  # give :first the higher seq, and the observed order flips.
  example explicit_seq_controls_clause_order() do
    c = fresh_class()

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_class ^c object.

        ^c >> tag
        | Self first |.

        ^c >> tag
        | Self second |.
        """
      end

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        method ^c tag Id.
        vm_retract_oapply Id _.
        """
      end

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        method ^c tag Id.
        vm_set_oapply Id 1 [Self, first] {}.
        vm_set_oapply Id 0 [Self, second] {}.
        """
      end

    {:atomic, {b, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall T Ts (tag ^c T).
        """
      end

    assert Map.get(b, "$Ts") == [:second, :first]
    :ok
  end

  # Reading a clause must not capture the query's variable names. `:defmethod`'s
  # stored head is `[self, method_name, head, body]`, so querying it with vars
  # also named `head`/`body` used to bind a var against a term containing itself
  # and fail the occurs-check — yielding nothing. Scanned clauses are now
  # standardized apart, so the query matches regardless of the names it uses.
  example clause_read_does_not_capture_query_vars() do
    {:atomic, {b, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall Head Heads (clause defmethod Head Body).
        """
      end

    assert Map.get(b, "$Heads") != []
    :ok
  end

  example clause_heads_refuse_cyclic_bindings() do
    {:atomic, {b, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @cycle_probe
        #{super => object}.

        cycle_probe >> wrapped_first
        | _Self (wrap X) X |.

        cycle_probe >> wrapped_second
        | _Self X (wrap X) |.

        cycle_probe >> twice
        | _Self X X |.

        new cycle_probe Probe.
        not {wrapped_first Probe Y Y}.
        not {wrapped_second Probe Z Z}.
        twice Probe (wrap W) Same.
        """
      end

    assert %AL.Goal.Compound{name: :wrap} = b["$Same"]
  end

  example unused_head_variables_preserve_open_calls_and_live_variables() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @unused_head_probe
        #{super => object}.

        unused_head_probe >> accepts
        | _Self _Unused |.

        unused_head_probe >> repeated
        | _Self X X |.

        unused_head_probe >> echoes
        | _Self X Result |
        = Result X.

        new unused_head_probe Probe.
        accepts Probe Open.
        var Open.
        not {repeated Probe 1 2}.
        repeated Probe 3 3.
        echoes Probe 4 Echo.
        """
      end

    assert bindings["$Echo"] == 4
  end

  example prepared_clause_cache_tracks_clause_replacement() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @prepared_clause_probe
        #{super => object}.

        prepared_clause_probe >> accepts
        | _Self _Unused |.

        new prepared_clause_probe Probe.
        accepts Probe anything.
        method prepared_clause_probe accepts Id.
        vm_retract_oapply Id _.
        vm_set_oapply Id [_Self, fixed] {}.
        not {accepts Probe other}.
        accepts Probe fixed.
        """
      end
  end

  example dispatch_tracks_method_rebinding() do
    c = fresh_class()
    probe = fresh_class()

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_class ^c object.

        ^c >> tag
        | _Self first |.

        ^c >> replacement
        | _Self second |.

        vm_set_class ^probe ^c.
        tag ^probe first.
        method ^c replacement ReplacementId.
        vm_retract_method ^c tag _.
        vm_set_method ^c tag ReplacementId.
        tag ^probe second.
        """
      end
  end

  # `:object`'s `reorder_clauses` rewrites a method's clauses into a given order.
  # `:list`'s `:at` is the 3-arg entry clause `[xs, n, x]` followed by two 4-arg
  # recursion clauses, so head arity (3 vs 4) is a rename-stable witness of clause
  # order. Swapping the first two ([x, y, z] -> [y, x, z]) moves the lone 3-arg
  # clause from first to second; swapping again restores `:at`, so the example
  # leaves the live method as it found it and stays idempotent across runs.
  example reorder_clauses_rewrites_and_restores_order() do
    assert at_clause_arities() == [3, 4, 4]

    swap_first_two_at_clauses()
    assert at_clause_arities() == [4, 3, 4]

    swap_first_two_at_clauses()
    assert at_clause_arities() == [3, 4, 4]
    :ok
  end

  # A clause body holding a cons cell with an unbound-var tail (`[h | t]`) must
  # survive `set_oapply`'s storage round-trip: `to_stored`'s list recursion used
  # to assume `Enum.map`-able (nil-terminated) lists, which crashed on the
  # improper list `[h | t]` produces before `h`/`t` are bound by a call.
  example defmethod_stores_clause_with_improper_list_arg() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        vm_set_class cons_arg_test object.

        cons_arg_test >> wrap
        | Self H T Out |
        = Out [H . T].
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        wrap cons_arg_test 1 [2, 3] Out.
        """
      end

    assert Map.get(bindings, "$Out") == [1, 2, 3]
    :ok
  end

  defp at_clause_arities() do
    {:atomic, {b, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        method list at Id.
        findall Head Heads (clause Id Head Body).
        """
      end

    Enum.map(Map.get(b, "$Heads"), &length/1)
  end

  defp swap_first_two_at_clauses() do
    {:atomic, {b, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        method list at Id.
        findall [Head, Body] Clauses (clause Id Head Body).
        """
      end

    [x, y, z] = Map.get(b, "$Clauses")
    reordered = [y, x, z]

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        reorder_clauses list at _ ^reordered.
        """
      end
  end
end
