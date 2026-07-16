defmodule AL.Package.Equations do
  @moduledoc """
  I am declarative integer arithmetic: `equation(self, t, u)` holds
  `t = u` over prefix terms (`[:add, a, b]`, `[:mul, a, b]`, leaves
  variables or integers) and schedules itself. Ground both sides, it
  checks; one unknown occurrence, it solves by algebra, multiplication
  dividing exactly or failing; more, it freezes on an unknown and
  re-posts itself when that binds.
  """

  use AL.Package

  defpackage :equations, version: 1, deps: [:bootstrap] do
    set_class(:equations, :object)

    defmethod(:equations, :equation, [self, t, u]) do
      implies do
        [ground(t), ground(u)] ->
          val(self, t, a)
          val(self, u, b)
          unify(a, b)

        [ground(u)] ->
          val(self, u, acc)
          settle(self, t, acc, t, u)

        [ground(t)] ->
          val(self, t, acc)
          settle(self, u, acc, t, u)

        :else ->
          var(self, [t, u], v)
          freeze(v, [equation(self, t, u)])
      end
    end

    # One unknown occurrence solves; several wait for one to bind.
    defmethod(:equations, :settle, [self, side, acc, t, u]) do
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

    defmethod(:equations, :val, [self, [:add, a, b], v]) do
      val(self, a, va)
      val(self, b, vb)
      is(v, va + vb)
    end

    defmethod(:equations, :val, [self, [:mul, a, b], v]) do
      val(self, a, va)
      val(self, b, vb)
      is(v, va * vb)
    end

    defmethod(:equations, :val, [_self, x, x]) do
    end

    ### Algebra walks to the unknown: addition subtracts away, and
    ### multiplication divides exactly or fails. The var gate runs
    ### first, else a variable would unify with the patterns below and
    ### the solver would generate terms instead of matching them.

    defmethod(:equations, :solve, [self, x, acc]) do
      implies do
        [var(x)] -> unify(x, acc)
        :else -> descend(self, x, acc)
      end
    end

    defmethod(:equations, :descend, [self, [:add, a, b], acc]) do
      implies do
        [ground(a)] ->
          val(self, a, va)
          is(rest, acc - va)
          solve(self, b, rest)

        :else ->
          val(self, b, vb)
          is(rest, acc - vb)
          solve(self, a, rest)
      end
    end

    defmethod(:equations, :descend, [self, [:mul, a, b], acc]) do
      implies do
        [ground(a)] ->
          val(self, a, va)
          is(z, rem(acc, va))
          unify(z, 0)
          is(rest, acc / va)
          solve(self, b, rest)

        :else ->
          val(self, b, vb)
          is(z, rem(acc, vb))
          unify(z, 0)
          is(rest, acc / vb)
          solve(self, a, rest)
      end
    end

    ### Unknown occurrences, one per solution on backtracking; the
    ### same gate keeps variables out of the structural patterns.

    defmethod(:equations, :var, [self, x, v]) do
      implies do
        [var(x)] -> unify(v, x)
        :else -> var_in(self, x, v)
      end
    end

    defmethod(:equations, :var_in, [self, [:add, a, b], v]) do
      alternative([var(self, a, v)], [var(self, b, v)])
    end

    defmethod(:equations, :var_in, [self, [:mul, a, b], v]) do
      alternative([var(self, a, v)], [var(self, b, v)])
    end

    defmethod(:equations, :var_in, [self, [a, b], v]) do
      alternative([var(self, a, v)], [var(self, b, v)])
    end
  end
end
