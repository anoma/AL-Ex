defmodule Examples.ALClauseCache do
  @moduledoc """
  I show the clause cache staying honest: repeated calls hit it,
  redefinition drops it, and a transaction reads its own writes.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example second_call_hits_the_cache() do
    branch = AL.Branch.fork()

    {:atomic, _} =
      run branch: branch.id do
        set_class(:cached, :object)

        defmethod(:cached, :answer, [_self, 1]) do
        end
      end

    {:atomic, {bindings, _}} =
      run branch: branch.id do
        answer(:cached, x)
      end

    assert AL.Var.deref(bindings, :"$x") == 1

    cached =
      Enum.filter(:ets.tab2list(:al_clause_cache), fn {key, _} ->
        elem(key, 0) == branch.id and elem(key, 1) == :clauses
      end)

    assert [{_key, [_clause]}] = cached

    {:atomic, {bindings, _}} =
      run branch: branch.id do
        answer(:cached, x)
      end

    assert AL.Var.deref(bindings, :"$x") == 1
    AL.Branch.discard(branch)
    cached
  end

  example redefinition_is_seen_at_once() do
    branch = AL.Branch.fork()

    {:atomic, _} =
      run branch: branch.id do
        set_class(:cached, :object)

        defmethod(:cached, :answer, [_self, 1]) do
        end
      end

    {:atomic, {bindings, _}} =
      run branch: branch.id do
        answer(:cached, x)
      end

    assert AL.Var.deref(bindings, :"$x") == 1

    {:atomic, _} =
      run branch: branch.id do
        forall([method(:cached, :answer, impl), clause(impl, h, _b)], [
          retract_oapply(impl, h)
        ])

        defmethod(:cached, :answer, [_self, 2]) do
        end
      end

    {:atomic, {bindings, _}} =
      run branch: branch.id do
        answer(:cached, x)
      end

    assert AL.Var.deref(bindings, :"$x") == 2
    AL.Branch.discard(branch)
    bindings
  end

  example a_transaction_reads_its_own_writes() do
    branch = AL.Branch.fork()

    {:atomic, {bindings, _}} =
      run branch: branch.id do
        set_class(:cached, :object)

        defmethod(:cached, :fresh, [_self, 7]) do
        end

        fresh(:cached, x)
      end

    assert AL.Var.deref(bindings, :"$x") == 7
    own = Enum.filter(:ets.tab2list(:al_clause_cache), &(elem(elem(&1, 0), 0) == branch.id))
    assert own == []
    AL.Branch.discard(branch)
    bindings
  end
end
