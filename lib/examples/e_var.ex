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
    AL.Var.unify([:"$x", 3, :"$x"], [:"$x", :"$x", :"$y"])
  end

  example unification_three() do
    inner_store = AL.Var.unify(:"$y", :"$x")
    AL.Var.unify(:"$x", 3, inner_store)
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

  example occurs_check_rejects_cycle() do
    # binding a var into a term that contains it would create a cyclic term;
    # the occurs check refuses, so unification fails (nil)
    assert AL.Var.unify(:"$x", [:"$x"]) == nil
    assert AL.Var.unify([:"$x"], :"$x") == nil
    assert AL.Var.occurs?(:"$x", {:f, [1, :"$x"]}, %{})

    # an improper list (cons with a variable tail) is walked without crashing
    refute AL.Var.occurs?(:"$x", [1 | :"$y"], %{})

    # a var that does not occur in the term still binds normally
    assert AL.Var.unify(:"$x", [1, 2, :"$y"]) == %{"$x": [1, 2, :"$y"]}
    :ok
  end

  example subst_and_find_vars_cover_map_keys() do
    bindings = AL.Var.unify(:"$k", :resolved)

    # a variable in key position is substituted, not left as a (freshened) var
    assert AL.Var.subst(%{:"$k" => :v}, bindings) == %{resolved: :v}

    # and find_vars sees variables in key position too
    assert MapSet.member?(AL.Var.find_vars(%{:"$k" => :v}), :"$k")
    :ok
  end

  example dif_survives_var_to_var_aliasing() do
    store = AL.Var.add_dif(%{}, :"$x", 1)

    # `$x` is still open, so unifying it with another open var aliases one to
    # the other rather than binding either to a concrete term — and which one
    # survives as the live representative is an internal choice, not
    # something calling code should have to predict. Bindings and constraints
    # live in the same store now — a constraint on `$x` rides along onto
    # whichever var ends up the live representative, no separate map to keep
    # in sync.
    aliased_store = AL.Var.unify(:"$x", :"$y", store)

    # whichever name is now live still owes `$x`'s dif constraint: binding
    # either name to the forbidden value has to fail.
    assert AL.Var.unify(:"$y", 1, aliased_store) == nil
    assert AL.Var.unify(:"$x", 1, aliased_store) == nil
    assert AL.Var.unify(:"$y", 2, aliased_store) != nil
    :ok
  end
end
