defmodule Examples.AL.Var do
  @moduledoc """
  I provide examples for AL.Var
  """

  use ExExample
  import ExUnit.Assertions

  example mnesia_pattern() do
    pattern = AL.Var.to_mnesia_pattern([%{name: :"$name"}, 3, :"$a"])
    assert [%{name: :"$1"}, 3, :"$2"] == pattern
    pattern
  end

  example unification() do
    bindings =
      AL.Var.unify([:"$self", %{name: :"$name"}, {:"$_", 3}], [
        :"$self",
        %{name: "alice", age: 32},
        {:_, 3}
      ])

    assert bindings == %{"$name": "alice"}
    bindings
  end

  example unification_two() do
    result = AL.Var.unify([:"$x", 3, :"$x"], [:"$x", :"$x", :"$y"])
    result
  end

  example unification_three() do
    result = AL.Var.unify(:"$x", 3, AL.Var.unify(:"$y", :"$x"))
    result
  end

  example substitution() do
    bindings = unification()

    substitution = AL.Var.subst([:"$self", %{name: :"$name"}, {:"$_", 3}], bindings)

    assert substitution == [:"$self", %{name: "alice"}, {:"$_", 3}]

    substitution
  end

  example find_vars() do
    AL.Var.find_vars([:"$self", %{name: :"$name"}, {:"$_", 3}])
  end

  example freshen_vars() do
    AL.Var.freshen(
      [:"$self", %{name: :"$name"}, {:"$_", 3}],
      Base.encode16(:crypto.strong_rand_bytes(2))
    )
  end
end
