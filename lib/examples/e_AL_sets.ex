defmodule Examples.ALSets do
  @moduledoc """
  I provide examples for the `:sets` package — a set is `%{class: :set, elems:
  list}`, where `elems` is always kept sorted and deduped. Canonical form
  means two sets with the same members are the identical term, so `==` is
  sufficient for set equality and every operation (`elem`, `insert`, `union`,
  `intersection`, `members`) reduces to a plain list operation.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example new_set_canonicalizes_elems() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:set, %{elems: [3, 1, 2, 1]}, s)
      end

    assert Map.get(bindings, :"$s") == %{class: :set, elems: [1, 2, 3]}
    :ok
  end

  example set_elem_checks_membership() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:set, %{elems: [4, 7]}, s)

        elem(s, 4)
        elem(s, 7)
        not [elem(s, 9)]

        unify(checked, true)
      end

    assert Map.get(bindings, :"$checked") == true
    :ok
  end

  example empty_set_has_no_elements() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:set, %{elems: []}, empty)
        not [elem(empty, 4)]
        unify(checked, true)
      end

    assert Map.get(bindings, :"$checked") == true
    :ok
  end

  example insert_into_empty_set_makes_a_singleton() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:set, %{elems: []}, empty)
        insert(empty, 4, s)
      end

    assert Map.get(bindings, :"$s") == %{class: :set, elems: [4]}
    :ok
  end

  example insert_existing_element_is_idempotent() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:set, %{elems: [4]}, s)
        insert(s, 4, s2)
      end

    assert Map.get(bindings, :"$s2") == Map.get(bindings, :"$s")
    :ok
  end

  example insert_new_element_grows_the_set() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:set, %{elems: [4]}, s)
        insert(s, 7, grown)
      end

    assert Map.get(bindings, :"$grown") == %{class: :set, elems: [4, 7]}
    :ok
  end

  example union_deduplicates_overlapping_elements() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:set, %{elems: [4]}, s1)
        new(:set, %{elems: [4]}, s2)
        union(s1, s2, u)
      end

    assert Map.get(bindings, :"$u") == %{class: :set, elems: [4]}
    :ok
  end

  example union_of_disjoint_sets_combines_elements() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:set, %{elems: [4]}, s1)
        new(:set, %{elems: [7]}, s2)
        union(s1, s2, u)
      end

    assert Map.get(bindings, :"$u") == %{class: :set, elems: [4, 7]}
    :ok
  end

  example union_is_canonical_regardless_of_operand_order() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:set, %{elems: [4]}, a1)
        new(:set, %{elems: [7]}, a2)
        union(a1, a2, u1)

        new(:set, %{elems: [7]}, b1)
        new(:set, %{elems: [4]}, b2)
        union(b1, b2, u2)
      end

    assert Map.get(bindings, :"$u1") == Map.get(bindings, :"$u2")
    :ok
  end

  example insert_with_unbound_receiver_never_grounds_to_a_class_atom() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        insert(s, 3, s1)
      end

    refute Map.get(bindings, :"$s") == :set
    :ok
  end

  example elem_generates_a_singleton_set_for_unbound_receiver() do
    {:atomic, {b1, _}} =
      run branch: :examples do
        elem(x, 7)
      end

    assert Map.get(b1, :"$x") == %{class: :set, elems: [7]}
    :ok
  end

  example elem_generates_with_both_receiver_and_element_open() do
    {:atomic, {b1, _}} =
      run branch: :examples do
        elem(e, x)
      end

    e1 = Map.get(b1, :"$e")
    x1 = Map.get(b1, :"$x")
    assert e1.class == :set
    assert e1.elems == [x1]
    assert AL.Var.var?(x1)
    :ok
  end

  example members_of_empty_set_is_empty_list() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:set, %{elems: []}, empty)
        members(empty, elems)
      end

    assert Map.get(bindings, :"$elems") == []
    :ok
  end

  example members_of_set_is_its_elems() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:set, %{elems: [4, 7]}, s)
        members(s, elems)
      end

    assert Map.get(bindings, :"$elems") == [4, 7]
    :ok
  end

  example members_constructs_a_canonical_set_from_a_member_list() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        members(s, [3, 1, 2, 1])
      end

    assert Map.get(bindings, :"$s") == %{class: :set, elems: [1, 2, 3]}
    :ok
  end

  example intersection_of_overlapping_sets_produces_a_set() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:set, %{elems: [3, 4]}, s1)
        new(:set, %{elems: [3, 5]}, s2)
        intersection(s1, s2, i)
      end

    assert Map.get(bindings, :"$i") == %{class: :set, elems: [3]}
    :ok
  end

  example intersection_of_disjoint_sets_is_empty() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:set, %{elems: [4]}, s1)
        new(:set, %{elems: [7]}, s2)
        intersection(s1, s2, i)
      end

    assert Map.get(bindings, :"$i") == %{class: :set, elems: []}
    :ok
  end
end
