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

  # Two clauses that both match the same call, so `findall` reveals their order.
  example clauses_are_tried_in_definition_order() do
    c = fresh_class()

    {:atomic, _} =
      run do
        set_class(^c, :object)
        defmethod(^c, :tag, [self, :first]) do end
        defmethod(^c, :tag, [self, :second]) do end
      end

    {:atomic, {b, _}} = run do findall(t, [tag(^c, t)], ts) end
    assert Map.get(b, :"$ts") == [:first, :second]
    :ok
  end

  # A fork rebuilds its projection by replaying the log, so this also pins that
  # clause order survives replay/rehydrate.
  example clause_order_survives_fork() do
    c = fresh_class()

    {:atomic, _} =
      run do
        set_class(^c, :object)
        defmethod(^c, :tag, [self, :first]) do end
        defmethod(^c, :tag, [self, :second]) do end
      end

    tip = AL.Branch.fork()

    {:atomic, {b, _}} = run branch: tip do findall(t, [tag(^c, t)], ts) end
    assert Map.get(b, :"$ts") == [:first, :second]

    AL.Branch.discard(tip)
    :ok
  end

  # Retract all clauses and reinsert them in the opposite order; the new order
  # should be what's observed. This is the basis any reorder helper relies on.
  example clause_reinsertion_controls_order() do
    c = fresh_class()

    {:atomic, _} =
      run do
        set_class(^c, :object)
        defmethod(^c, :tag, [self, :first]) do end
        defmethod(^c, :tag, [self, :second]) do end
      end

    {:atomic, _} =
      run do
        method(^c, :tag, id)
        retract_oapply(id, _)
      end

    {:atomic, _} =
      run do
        method(^c, :tag, id)
        set_oapply(id, [self, :second]) do end
        set_oapply(id, [self, :first]) do end
      end

    {:atomic, {b, _}} = run do findall(t, [tag(^c, t)], ts) end
    assert Map.get(b, :"$ts") == [:second, :first]
    :ok
  end
end
