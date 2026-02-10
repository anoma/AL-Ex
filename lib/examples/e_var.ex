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

    assert bindings == %{"$_": :"$_", "$name": "alice", "$self": :"$self"}
    bindings
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
end
