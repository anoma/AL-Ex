defmodule AL.TransactionProgram.Equations do
  @moduledoc """
  I am declarative integer arithmetic: `equation(self, t, u)` holds
  `t = u` over prefix terms (`[:add, a, b]`, `[:mul, a, b]`, leaves
  variables or integers) and schedules itself. Ground both sides, it
  checks; one unknown occurrence, it solves by algebra, multiplication
  dividing exactly or failing; more, it freezes on an unknown and
  re-posts itself when that binds.
  """

  use AL.TransactionProgram

  defprogram :equations, version: 1, deps: [:bootstrap] do
    vm_set_class(:equation_solver, :object)

    defmethod(:equation_solver, :equation, [self, t, u]) do
      implies do
        [vm_ground(t), vm_ground(u)] ->
          val(self, t, a)
          val(self, u, b)
          unify(a, b)

        [vm_ground(u)] ->
          val(self, u, acc)
          settle(self, t, acc, t, u)

        [vm_ground(t)] ->
          val(self, t, acc)
          settle(self, u, acc, t, u)

        :else ->
          var(self, [t, u], v)
          freeze(v, [equation(self, t, u)])
      end
    end

    # One unknown occurrence solves; several wait for one to bind.
    defmethod(:equation_solver, :settle, [self, side, acc, t, u]) do
      findall(w, [var(self, side, w)], unknowns)

      implies do
        [unify(unknowns, [_lone])] ->
          solve(self, side, acc)

        :else ->
          var(self, side, v)
          freeze(v, [equation(self, t, u)])
      end
    end

    ### Evaluation of ground prefix terms.

    defmethod(:equation_solver, :val, [self, [:add, a, b], v]) do
      val(self, a, va)
      val(self, b, vb)
      vm_is(v, va + vb)
    end

    defmethod(:equation_solver, :val, [self, [:mul, a, b], v]) do
      val(self, a, va)
      val(self, b, vb)
      vm_is(v, va * vb)
    end

    defmethod(:equation_solver, :val, [_self, x, x])

    ### Algebra walks to the unknown: addition subtracts away, and
    ### multiplication divides exactly or fails. The var gate runs
    ### first, else a variable would unify with the patterns below and
    ### the solver would generate terms instead of matching them.

    defmethod(:equation_solver, :solve, [self, x, acc]) do
      implies do
        [var(x)] -> unify(x, acc)
        :else -> descend(self, x, acc)
      end
    end

    defmethod(:equation_solver, :descend, [self, [:add, a, b], acc]) do
      implies do
        [vm_ground(a)] ->
          val(self, a, va)
          vm_is(rest, acc - va)
          solve(self, b, rest)

        :else ->
          val(self, b, vb)
          vm_is(rest, acc - vb)
          solve(self, a, rest)
      end
    end

    defmethod(:equation_solver, :descend, [self, [:mul, a, b], acc]) do
      implies do
        [vm_ground(a)] ->
          val(self, a, va)
          vm_is(z, rem(acc, va))
          unify(z, 0)
          vm_is(rest, acc / va)
          solve(self, b, rest)

        :else ->
          val(self, b, vb)
          vm_is(z, rem(acc, vb))
          unify(z, 0)
          vm_is(rest, acc / vb)
          solve(self, a, rest)
      end
    end

    ### Unknown occurrences, one per solution on backtracking; the
    ### same gate keeps variables out of the structural patterns.

    defmethod(:equation_solver, :var, [self, x, v]) do
      implies do
        [var(x)] -> unify(v, x)
        :else -> var_in(self, x, v)
      end
    end

    defmethod(:equation_solver, :var_in, [self, [:add, a, b], v]) do
      alternative([var(self, a, v)], [var(self, b, v)])
    end

    defmethod(:equation_solver, :var_in, [self, [:mul, a, b], v]) do
      alternative([var(self, a, v)], [var(self, b, v)])
    end

    defmethod(:equation_solver, :var_in, [self, [a, b], v]) do
      alternative([var(self, a, v)], [var(self, b, v)])
    end
  end
end
