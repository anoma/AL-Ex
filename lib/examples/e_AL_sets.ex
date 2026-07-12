defmodule Examples.ALSets do
  @moduledoc """
  I provide examples for the `:sets` package — `single`/`union`/`empty_set` as
  ephemeral, term-composed sets (never durable, never gensym'd), with `elem`
  running both as an ordinary membership check and, with an unbound receiver,
  as a generator that hypothesises `single`/`union` structure via `dispatch`'s
  `:generate_ephemeral` mechanism.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example single_is_ephemeral() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:single, %{elem: 4}, s)
      end

    assert Map.get(bindings, :"$s") == %{class: :single, elem: 4}
    :ok
  end

  example union_elem_checks_membership() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:single, %{elem: 4}, s1)
        new(:single, %{elem: 7}, s2)
        new(:union, %{left: s1, right: s2}, u)

        elem(u, 4)
        elem(u, 7)
        not [elem(u, 9)]

        unify(checked, true)
      end

    assert Map.get(bindings, :"$checked") == true
    :ok
  end

  example empty_set_has_no_elements() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        not [elem(:empty_set, 4)]
        unify(checked, true)
      end

    assert Map.get(bindings, :"$checked") == true
    :ok
  end

  example insert_into_empty_set_makes_single() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        insert(:empty_set, 4, s)
      end

    assert Map.get(bindings, :"$s") == %{class: :single, elem: 4}
    :ok
  end

  example insert_existing_element_is_idempotent() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:single, %{elem: 4}, s)
        insert(s, 4, s2)
      end

    assert Map.get(bindings, :"$s2") == Map.get(bindings, :"$s")
    :ok
  end

  example insert_new_element_grows_a_union() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:single, %{elem: 4}, s)
        insert(s, 7, grown)
        elem(grown, 4)
        elem(grown, 7)
      end

    assert Map.get(bindings, :"$grown").class == :union
    :ok
  end

  # `union` no longer rejects overlapping operands at construction time — the
  # check couldn't tell "genuinely overlapping" apart from "operand isn't
  # grounded yet" (see `elem`'s membership check being a generator itself),
  # so a duplicated element can survive in the tree. `elem`'s `alternative`
  # already treats membership as an OR, so queries stay correct regardless.
  example union_construction_allows_overlapping_operands() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:single, %{elem: 4}, s1)
        new(:single, %{elem: 4}, s2)
        new(:union, %{left: s1, right: s2}, u)
        elem(u, 4)
      end

    assert Map.get(bindings, :"$u").class == :union
    :ok
  end

  example union_construction_succeeds_when_operands_are_disjoint() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:single, %{elem: 4}, s1)
        new(:single, %{elem: 7}, s2)
        new(:union, %{left: s1, right: s2}, u)
      end

    assert Map.get(bindings, :"$u").class == :union
    :ok
  end

  # Regression: `insert(s, 3, s1)` with `s` unbound must never ground `s` to a
  # bare class atom like `:union`. `dispatch`'s `GetClass` enumeration offers
  # every durable object with a `class` row as a candidate, including class
  # atoms themselves — `:union`/`:single` failing `:elem` (called on the bare
  # atom, not a map) used to look identical to "a legitimate, currently-empty
  # set" to `insert`'s guard. Fixed at the root, in `method_scopes`: a class
  # atom no longer resolves methods meant for its instances when used directly
  # as a receiver.
  example insert_with_unbound_receiver_never_grounds_to_a_class_atom() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        insert(s, 3, s1)
      end

    refute Map.get(bindings, :"$s") == :union
    refute Map.get(bindings, :"$s") == :single
    :ok
  end

  # `elem(x, 7)` with `x` unbound: `dispatch`'s `:generate_ephemeral` scan offers
  # `single`/`union` as structural hypotheses, the same way lists offer `[]`/cons —
  # so this generates a `single` containing 7 out of nothing, not just searches.
  example elem_generates_ephemeral_sets_for_unbound_receiver() do
    {:atomic, {b1, _}} =
      run branch: :examples do
        elem(x, 7)
      end

    assert Map.get(b1, :"$x") == %{class: :single, elem: 7}
    :ok
  end

  # A fully open query (both receiver and element unbound) still generates: the
  # element stays aliased to itself rather than being forced to a concrete value,
  # the same way an open Prolog query would.
  example elem_generates_with_both_receiver_and_element_open() do
    {:atomic, {b1, state}} =
      run branch: :examples do
        elem(e, x)
      end

    e1 = Map.get(b1, :"$e")
    x1 = Map.get(b1, :"$x")
    assert e1.class == :single
    assert e1.elem == x1
    assert AL.Var.var?(x1)

    {:atomic, {b2, _}} = next_solution(state)
    assert Map.get(b2, :"$e").class == :union

    :ok
  end
end
