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

  # # `insert`'s grow clause resolves `self` bidirectionally: given `x` and the
  # # already-known result, what could `self` have been? This works because the
  # # construction goals run *before* the `not [elem(self, x)]` guard — unifying
  # # the freshly-built `%{class: :union, left: self, right: s2}` against the
  # # known result pins `self` down via ordinary head unification, so the guard
  # # runs against an already-concrete `self` instead of a bare unbound var
  # # (which is what made it unsound before: `elem` on a bare receiver always
  # # succeeds via generation, so `not[...]` always failed).
  # example insert_resolves_self_from_a_known_result() do
  #   {:atomic, {bindings, _}} =
  #     run branch: :examples do
  #       new(:single, %{elem: 4}, s1)
  #       new(:single, %{elem: 7}, s2)
  #       new(:union, %{left: s1, right: s2}, grown)
  #       insert(self, 7, grown)
  #     end

  #   assert Map.get(bindings, :"$self") == %{class: :single, elem: 4}
  #   :ok
  # end

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

  example members_of_empty_set_is_empty_list() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        members(:empty_set, elems)
      end

    assert Map.get(bindings, :"$elems") == []
    :ok
  end

  example members_of_single_is_one_element_list() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:single, %{elem: 4}, s)
        members(s, elems)
      end

    assert Map.get(bindings, :"$elems") == [4]
    :ok
  end

  # `members` is deliberately a one-direction `findall` over `elem`, not a
  # structural walk — `elem`'s own recursion (`alternative` over left/right)
  # already correctly reaches every leaf at any depth, so `findall` collecting
  # over it is correct at any nesting, with no risk of dropping an element the
  # way a hand-rolled structural recursion could get wrong (see the nested
  # example below, which is exactly the case an earlier structural-recursion
  # attempt got wrong).
  example members_of_union_is_both_sides_concatenated() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:single, %{elem: 4}, s1)
        new(:single, %{elem: 7}, s2)
        new(:union, %{left: s1, right: s2}, u)
        members(u, elems)
      end

    assert Map.get(bindings, :"$elems") == [4, 7]
    :ok
  end

  example members_of_a_union_with_a_nested_multi_element_side() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:single, %{elem: 1}, s1)
        new(:single, %{elem: 2}, s2)
        new(:union, %{left: s1, right: s2}, nested)
        new(:single, %{elem: 3}, s3)
        new(:union, %{left: nested, right: s3}, u)
        members(u, elems)
      end

    assert Enum.sort(Map.get(bindings, :"$elems")) == [1, 2, 3]
    :ok
  end

  # `members` only supports the direction its `findall` was built for: given a
  # concrete set, list its elements. Given a *target* member list instead (an
  # unbound receiver, asking `members` to construct a matching set), it isn't
  # supported — `self` still has to be hypothesised through the same ephemeral
  # generation `elem` uses, and nothing in `members`'s `findall` bounds that
  # search by the list it was handed, so it degrades into the same open-ended
  # generation `findall` was already unsafe over. Documented as an expected,
  # legible abort rather than left to fail silently or hang.
  example members_does_not_support_constructing_a_set_from_a_member_list() do
    {:aborted, reason} =
      run branch: :examples do
        members(_s, [1, 2, 3])
      end

    assert reason.reason == {:resource_limit_exceeded, 5_000}
    :ok
  end

  example intersection_of_overlapping_sets_produces_a_set() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        insert(:empty_set, 3, s)
        insert(s, 4, s1)
        insert(s, 5, s2)
        intersection(s1, s2, i)
      end

    assert Map.get(bindings, :"$i") == %{class: :single, elem: 3}
    :ok
  end

  example intersection_of_disjoint_sets_is_empty_set() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:single, %{elem: 4}, s1)
        new(:single, %{elem: 7}, s2)
        intersection(s1, s2, i)
      end

    assert Map.get(bindings, :"$i") == :empty_set
    :ok
  end
end
