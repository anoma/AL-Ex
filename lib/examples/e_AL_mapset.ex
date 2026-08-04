defmodule Examples.ALMapset do
  @moduledoc """
  I provide examples for the `:mapset_value` package — a set is `%{class: :mapset_value,
  elems: map}`, where `elems` holds each member as a key (value unused).
  Elixir/Erlang map equality is content-based regardless of insertion order,
  so two mapsets with the same members are the identical term and `==` is
  sufficient for set equality. Elements must be ground: an unbound element
  can't be hashed into the map key space.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example new_mapset_canonicalizes_elems() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:mapset_value, %{elems: [3, 1, 2, 1]}, s)
      end

    assert Map.get(bindings, :"$s") == %{
             class: :mapset_value,
             elems: %{1 => true, 2 => true, 3 => true}
           }

    :ok
  end

  example mapset_elem_checks_membership() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:mapset_value, %{elems: [4, 7]}, s)

        elem(s, 4)
        elem(s, 7)
        not [elem(s, 9)]

        unify(checked, true)
      end

    assert Map.get(bindings, :"$checked") == true
    :ok
  end

  example empty_mapset_has_no_elements() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:mapset_value, %{elems: []}, empty)
        not [elem(empty, 4)]
        unify(checked, true)
      end

    assert Map.get(bindings, :"$checked") == true
    :ok
  end

  example insert_into_empty_mapset_makes_a_singleton() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:mapset_value, %{elems: []}, empty)
        insert(empty, 4, s)
      end

    assert Map.get(bindings, :"$s") == %{class: :mapset_value, elems: %{4 => true}}
    :ok
  end

  example insert_existing_element_is_idempotent() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:mapset_value, %{elems: [4]}, s)
        insert(s, 4, s2)
      end

    assert Map.get(bindings, :"$s2") == Map.get(bindings, :"$s")
    :ok
  end

  example insert_new_element_grows_the_mapset() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:mapset_value, %{elems: [4]}, s)
        insert(s, 7, grown)
      end

    assert Map.get(bindings, :"$grown") == %{class: :mapset_value, elems: %{4 => true, 7 => true}}
    :ok
  end

  example union_deduplicates_overlapping_elements() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:mapset_value, %{elems: [4]}, s1)
        new(:mapset_value, %{elems: [4]}, s2)
        union(s1, s2, u)
      end

    assert Map.get(bindings, :"$u") == %{class: :mapset_value, elems: %{4 => true}}
    :ok
  end

  example union_of_disjoint_mapsets_combines_elements() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:mapset_value, %{elems: [4]}, s1)
        new(:mapset_value, %{elems: [7]}, s2)
        union(s1, s2, u)
      end

    assert Map.get(bindings, :"$u") == %{class: :mapset_value, elems: %{4 => true, 7 => true}}
    :ok
  end

  example insert_fails_on_a_wholly_unbound_receiver() do
    # Unlike the old list-backed `:set`, an unbound receiver's placeholder
    # `elems` ivar is a bare var, not an open-tailed list — maps have no
    # structural-empty-map dispatch candidate the way lists have `[]`, so
    # there's nothing for `map_put` to generatively resolve it to.
    result =
      run branch: :examples do
        insert(s, 3, s1)
      end

    assert {:aborted, _} = result
    :ok
  end

  example elem_generates_a_singleton_mapset_for_unbound_receiver() do
    {:atomic, {b1, _}} =
      run branch: :examples do
        elem(x, 7)
      end

    assert Map.get(b1, :"$x") == %{class: :mapset_value, elems: %{7 => true}}
    :ok
  end

  example elem_fails_when_receiver_and_element_are_both_open() do
    result =
      run branch: :examples do
        elem(e, x)
      end

    assert {:aborted, _} = result
    :ok
  end

  example members_of_empty_mapset_is_empty_list() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:mapset_value, %{elems: []}, empty)
        members(empty, elems)
      end

    assert Map.get(bindings, :"$elems") == []
    :ok
  end

  example members_of_mapset_is_its_elems() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:mapset_value, %{elems: [4, 7]}, s)
        members(s, elems)
      end

    assert Enum.sort(Map.get(bindings, :"$elems")) == [4, 7]
    :ok
  end

  example members_constructs_a_canonical_mapset_from_a_member_list() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        members(s, [3, 1, 2, 1])
      end

    assert Map.get(bindings, :"$s") == %{
             class: :mapset_value,
             elems: %{1 => true, 2 => true, 3 => true}
           }

    :ok
  end

  example intersection_of_overlapping_mapsets_produces_a_mapset() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:mapset_value, %{elems: [3, 4]}, s1)
        new(:mapset_value, %{elems: [3, 5]}, s2)
        intersection(s1, s2, i)
      end

    assert Map.get(bindings, :"$i") == %{class: :mapset_value, elems: %{3 => true}}
    :ok
  end

  example intersection_of_disjoint_mapsets_is_empty() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        new(:mapset_value, %{elems: [4]}, s1)
        new(:mapset_value, %{elems: [7]}, s2)
        intersection(s1, s2, i)
      end

    assert Map.get(bindings, :"$i") == %{class: :mapset_value, elems: %{}}
    :ok
  end
end
