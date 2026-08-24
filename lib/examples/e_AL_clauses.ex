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
    {:atomic, {b, _}} =
      run branch: :examples do
        vm_method(:list, :reverse, m)
        vm_clause(m, [[h | t], out], body)
        call([[h | t], out], body, [[1, 2, 3], result])
      end

    assert Map.get(b, :"$result") == [3, 2, 1]
    b
  end

  # Two clauses that both match the same call, so `findall` reveals their order.
  example clauses_are_tried_in_definition_order() do
    c = fresh_class()

    {:atomic, _} =
      run branch: :examples do
        vm_set_class(^c, :object)

        defmethod(^c, :tag, [self, :first])

        defmethod(^c, :tag, [self, :second])
      end

    {:atomic, {b, _}} =
      run branch: :examples do
        findall(t, [tag(^c, t)], ts)
      end

    assert Map.get(b, :"$ts") == [:first, :second]
    :ok
  end

  # A fork rebuilds its projection by replaying the log, so this also pins that
  # clause order survives replay/rehydrate.
  example clause_order_survives_fork() do
    c = fresh_class()

    {:atomic, _} =
      run branch: :examples do
        vm_set_class(^c, :object)

        defmethod(^c, :tag, [self, :first])

        defmethod(^c, :tag, [self, :second])
      end

    tip = AL.Branch.fork(:tip, %AL.Branch{id: :examples})

    {:atomic, {b, _}} =
      run branch: tip.id do
        findall(t, [tag(^c, t)], ts)
      end

    assert Map.get(b, :"$ts") == [:first, :second]

    AL.Branch.discard(tip)
    :ok
  end

  # Retract all clauses and reinsert them in the opposite order; the new order
  # should be what's observed. This is the basis any reorder helper relies on.
  example clause_reinsertion_controls_order() do
    c = fresh_class()

    {:atomic, _} =
      run branch: :examples do
        vm_set_class(^c, :object)

        defmethod(^c, :tag, [self, :first])

        defmethod(^c, :tag, [self, :second])
      end

    {:atomic, _} =
      run branch: :examples do
        vm_method(^c, :tag, id)
        vm_retract_oapply(id, _)
      end

    {:atomic, _} =
      run branch: :examples do
        vm_method(^c, :tag, id)

        vm_set_oapply(id, [self, :second]) do
        end

        vm_set_oapply(id, [self, :first]) do
        end
      end

    {:atomic, {b, _}} =
      run branch: :examples do
        findall(t, [tag(^c, t)], ts)
      end

    assert Map.get(b, :"$ts") == [:second, :first]
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
      run branch: :examples do
        vm_set_class(^c, :object)
        defmethod(^c, :tag, [self, :first])
      end

    {:atomic, {b, _}} =
      run branch: :examples do
        vm_method(^c, :tag, id)
        vm_clause(id, seq_before, [_self, :first], _)
        vm_retract_oapply(id, [_self, :first])

        vm_set_oapply(id, [self, :second]) do
        end

        vm_clause(id, seq_after, [_self, :second], _)
      end

    assert Map.get(b, :"$seq_after") > Map.get(b, :"$seq_before")
    :ok
  end

  # `clause/4` surfaces each clause's `seq`, so a reorder can read current
  # positions before deciding new ones.
  example clause_exposes_seq() do
    c = fresh_class()

    {:atomic, _} =
      run branch: :examples do
        vm_set_class(^c, :object)

        defmethod(^c, :tag, [self, :first])

        defmethod(^c, :tag, [self, :second])
      end

    {:atomic, {b, _}} =
      run branch: :examples do
        vm_method(^c, :tag, id)
        findall(s, [vm_clause(id, s, h, body)], seqs)
      end

    assert Map.get(b, :"$seqs") == [0, 1]
    :ok
  end

  # `set_oapply/4` places a clause at an explicit `seq`, so order follows the
  # seq you assign rather than insertion order: insert :first then :second but
  # give :first the higher seq, and the observed order flips.
  example explicit_seq_controls_clause_order() do
    c = fresh_class()

    {:atomic, _} =
      run branch: :examples do
        vm_set_class(^c, :object)

        defmethod(^c, :tag, [self, :first])

        defmethod(^c, :tag, [self, :second])
      end

    {:atomic, _} =
      run branch: :examples do
        vm_method(^c, :tag, id)
        vm_retract_oapply(id, _)
      end

    {:atomic, _} =
      run branch: :examples do
        vm_method(^c, :tag, id)

        vm_set_oapply(id, 1, [self, :first]) do
        end

        vm_set_oapply(id, 0, [self, :second]) do
        end
      end

    {:atomic, {b, _}} =
      run branch: :examples do
        findall(t, [tag(^c, t)], ts)
      end

    assert Map.get(b, :"$ts") == [:second, :first]
    :ok
  end

  # Reading a clause must not capture the query's variable names. `:defmethod`'s
  # stored head is `[self, method_name, head, body]`, so querying it with vars
  # also named `head`/`body` used to bind a var against a term containing itself
  # and fail the occurs-check — yielding nothing. Scanned clauses are now
  # standardized apart, so the query matches regardless of the names it uses.
  example clause_read_does_not_capture_query_vars() do
    {:atomic, {b, _}} =
      run branch: :examples do
        findall(head, [vm_clause(:defmethod, head, body)], heads)
      end

    assert Map.get(b, :"$heads") != []
    :ok
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
      run branch: :examples do
        vm_set_class(:cons_arg_test, :object)

        defmethod(:cons_arg_test, :wrap, [self, h, t, out]) do
          unify(out, [h | t])
        end
      end

    {:atomic, {bindings, _}} =
      run branch: :examples do
        wrap(:cons_arg_test, 1, [2, 3], out)
      end

    assert Map.get(bindings, :"$out") == [1, 2, 3]
    :ok
  end

  defp at_clause_arities() do
    {:atomic, {b, _}} =
      run branch: :examples do
        vm_method(:list, :at, id)
        findall(head, [vm_clause(id, head, body)], heads)
      end

    Enum.map(Map.get(b, :"$heads"), &length/1)
  end

  defp swap_first_two_at_clauses() do
    {:atomic, {b, _}} =
      run branch: :examples do
        vm_method(:list, :at, id)
        findall([head, body], [vm_clause(id, head, body)], clauses)
      end

    [x, y, z] = Map.get(b, :"$clauses")
    reordered = [y, x, z]

    {:atomic, _} =
      run branch: :examples do
        reorder_clauses(:list, :at, _, ^reordered)
      end
  end
end
