defmodule Examples.ALVarSubstrate do
  @moduledoc """
  I test `AL.Var` directly -- calling `unify`/`subst`/`freshen`/`find_vars`/
  `occurs?` on a plain store map, with no `run`/`interp`/dispatch involved.
  Every other example file in this suite exercises AL.Var only indirectly,
  through the language surface; this one is substrate-level, pinning the
  store/unification primitives everything else is built on.
  """

  use ExExample
  import ExUnit.Assertions

  example mnesia_pattern() do
    pattern = AL.Mnesia.specification([%{name: {:"$var", "name"}}, 3, {:"$var", "a"}])
    assert [{[%{name: :"$1"}, 3, :"$2"], [], [:"$_"]}] == pattern
    pattern
  end

  example unification() do
    bindings =
      AL.Var.unify(
        [
          {:"$var", "self"},
          %{name: {:"$var", "name"}, age: {:"$var", "age"}},
          {{:"$var", "_"}, 3}
        ],
        [
          {:"$var", "self"},
          %{name: "alice", age: 32},
          {:_, 3}
        ]
      )

    assert bindings == %{{:"$var", "name"} => "alice", {:"$var", "age"} => 32}
    assert AL.Var.unify(%{name: {:"$var", "name"}}, %{name: "alice", age: 32}) == nil
    assert AL.Var.unify(%{op: {:"$var", "op"}}, %{num: 2}) == nil
    bindings
  end

  # `x` appears twice in the left list (once ground-bound via position 2,
  # once still-open in position 3) -- both derefs to the one value regardless
  # of which side did the binding.
  example goal_bodies_unify_as_data() do
    plus = %AL.Goal.OApply{method_id: :+, args: [1, 2]}

    bindings =
      AL.Var.unify(%AL.Goal.Eq{a: {:"$var", "n"}, b: plus}, %AL.Goal.Eq{
        a: {:"$var", "n"},
        b: {:"$var", "expr"}
      })

    assert bindings == %{{:"$var", "expr"} => plus}
    bindings
  end

  example unification_two() do
    store =
      AL.Var.unify([{:"$var", "x"}, 3, {:"$var", "x"}], [
        {:"$var", "x"},
        {:"$var", "x"},
        {:"$var", "y"}
      ])

    assert AL.Var.deref(store, {:"$var", "x"}) == 3
    assert AL.Var.deref(store, {:"$var", "y"}) == 3
    store
  end

  # Two open vars aliased first, then one of them bound -- which one ends up
  # holding the concrete value vs. pointing at an alias is an internal
  # choice (see `dif_survives_var_to_var_aliasing` below), so this asserts
  # via `deref` on both names rather than the raw store shape.
  example unification_three() do
    inner_store = AL.Var.unify({:"$var", "y"}, {:"$var", "x"})
    store = AL.Var.unify({:"$var", "x"}, 3, inner_store)
    assert AL.Var.deref(store, {:"$var", "x"}) == 3
    assert AL.Var.deref(store, {:"$var", "y"}) == 3
    store
  end

  example substitution() do
    bindings = unification()

    substitution =
      AL.Var.subst([{:"$var", "self"}, %{name: {:"$var", "name"}}, {{:"$var", "_"}, 3}], bindings)

    assert substitution == [{:"$var", "self"}, %{name: "alice"}, {{:"$var", "_"}, 3}]

    substitution
  end

  # `{:"$var", "_"}` is itself a `$`-prefixed atom, so `find_vars` (a plain structural
  # scan) reports it same as any other var -- the wildcard's "matches
  # anything, binds nothing" behavior is a dispatch-time convention, not
  # something `find_vars` itself special-cases.
  example find_vars() do
    vars = AL.Var.find_vars([{:"$var", "self"}, %{name: {:"$var", "name"}}, {{:"$var", "_"}, 3}])
    assert vars == MapSet.new([{:"$var", "self"}, {:"$var", "name"}, {:"$var", "_"}])
    vars
  end

  # Unlike `find_vars`, `freshen` *does* special-case `{:"$var", "_"}` -- it passes
  # through unchanged instead of being wrapped, since freshening exists to
  # keep two calls' vars from colliding, and the wildcard never binds
  # anything for a collision to happen to.
  example freshen_vars() do
    suffix = Base.encode16(:crypto.strong_rand_bytes(2))

    freshened =
      AL.Var.freshen([{:"$var", "self"}, %{name: {:"$var", "name"}}, {{:"$var", "_"}, 3}], suffix)

    assert freshened == [
             {:"$fresh", {:"$var", "self"}, suffix},
             %{name: {:"$fresh", {:"$var", "name"}, suffix}},
             {{:"$var", "_"}, 3}
           ]

    freshened
  end

  example occurs_check_rejects_cycle() do
    # binding a var into a term that contains it would create a cyclic term;
    # the occurs check refuses, so unification fails (nil)
    assert AL.Var.unify({:"$var", "x"}, [{:"$var", "x"}]) == nil
    assert AL.Var.unify([{:"$var", "x"}], {:"$var", "x"}) == nil
    assert AL.Var.occurs?({:"$var", "x"}, {:f, [1, {:"$var", "x"}]}, %{})

    # an improper list (cons with a variable tail) is walked without crashing
    refute AL.Var.occurs?({:"$var", "x"}, [1 | {:"$var", "y"}], %{})

    # a var that does not occur in the term still binds normally
    assert AL.Var.unify({:"$var", "x"}, [1, 2, {:"$var", "y"}]) == %{
             {:"$var", "x"} => [1, 2, {:"$var", "y"}]
           }

    :ok
  end

  example subst_and_find_vars_cover_map_keys() do
    bindings = AL.Var.unify({:"$var", "k"}, :resolved)

    # a variable in key position is substituted, not left as a (freshened) var
    assert AL.Var.subst(%{{:"$var", "k"} => :v}, bindings) == %{resolved: :v}

    # and find_vars sees variables in key position too
    assert MapSet.member?(AL.Var.find_vars(%{{:"$var", "k"} => :v}), {:"$var", "k"})
    :ok
  end

  example dif_survives_var_to_var_aliasing() do
    store = AL.Var.add_dif(%{}, {:"$var", "x"}, 1)

    # `$x` is still open, so unifying it with another open var aliases one to
    # the other rather than binding either to a concrete term — and which one
    # survives as the live representative is an internal choice, not
    # something calling code should have to predict. Bindings and constraints
    # live in the same store now — a constraint on `$x` rides along onto
    # whichever var ends up the live representative, no separate map to keep
    # in sync.
    aliased_store = AL.Var.unify({:"$var", "x"}, {:"$var", "y"}, store)

    # whichever name is now live still owes `$x`'s dif constraint: binding
    # either name to the forbidden value has to fail.
    assert AL.Var.unify({:"$var", "y"}, 1, aliased_store) == nil
    assert AL.Var.unify({:"$var", "x"}, 1, aliased_store) == nil
    assert AL.Var.unify({:"$var", "y"}, 2, aliased_store) != nil
    :ok
  end
end
