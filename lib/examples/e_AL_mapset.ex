defmodule Examples.ALMapset do
  @moduledoc """
  I provide examples for the `:mapset_value` class — a set is `%{class: :mapset_value,
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
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new mapset_value #{elems => [3, 1, 2, 1]} S.
        """
      end

    assert Map.get(bindings, :"$S") == %{
             class: :mapset_value,
             elems: %{1 => true, 2 => true, 3 => true}
           }

    :ok
  end

  example mapset_elem_checks_membership() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new mapset_value #{elems => [4, 7]} S.
        elem S 4.
        elem S 7.
        not (elem S 9).
        = Checked true.
        """
      end

    assert Map.get(bindings, :"$Checked") == true
    :ok
  end

  example empty_mapset_has_no_elements() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new mapset_value #{elems => []} Empty.
        not (elem Empty 4).
        = Checked true.
        """
      end

    assert Map.get(bindings, :"$Checked") == true
    :ok
  end

  example insert_into_empty_mapset_makes_a_singleton() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new mapset_value #{elems => []} Empty.
        insert Empty 4 S.
        """
      end

    assert Map.get(bindings, :"$S") == %{class: :mapset_value, elems: %{4 => true}}
    :ok
  end

  example insert_existing_element_is_idempotent() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new mapset_value #{elems => [4]} S.
        insert S 4 S2.
        """
      end

    assert Map.get(bindings, :"$S2") == Map.get(bindings, :"$S")
    :ok
  end

  example insert_new_element_grows_the_mapset() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new mapset_value #{elems => [4]} S.
        insert S 7 Grown.
        """
      end

    assert Map.get(bindings, :"$Grown") == %{class: :mapset_value, elems: %{4 => true, 7 => true}}
    :ok
  end

  example union_deduplicates_overlapping_elements() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new mapset_value #{elems => [4]} S1.
        new mapset_value #{elems => [4]} S2.
        union S1 S2 U.
        """
      end

    assert Map.get(bindings, :"$U") == %{class: :mapset_value, elems: %{4 => true}}
    :ok
  end

  example union_of_disjoint_mapsets_combines_elements() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new mapset_value #{elems => [4]} S1.
        new mapset_value #{elems => [7]} S2.
        union S1 S2 U.
        """
      end

    assert Map.get(bindings, :"$U") == %{class: :mapset_value, elems: %{4 => true, 7 => true}}
    :ok
  end

  example insert_fails_on_a_wholly_unbound_receiver() do
    # Unlike the old list-backed `:set`, an unbound receiver's placeholder
    # `elems` ivar is a bare var, not an open-tailed list — maps have no
    # structural-empty-map dispatch candidate the way lists have `[]`, so
    # there's nothing for `map_put` to generatively resolve it to.
    result =
      run branch: Examples.Support.branch() do
        ~AL"""
        insert S 3 S1.
        """
      end

    assert {:aborted, _} = result
    :ok
  end

  example elem_generates_a_singleton_mapset_for_unbound_receiver() do
    {:atomic, {b1, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        elem X 7.
        """
      end

    assert Map.get(b1, :"$X") == %{class: :mapset_value, elems: %{7 => true}}
    :ok
  end

  example elem_fails_when_receiver_and_element_are_both_open() do
    result =
      run branch: Examples.Support.branch() do
        ~AL"""
        isa E mapset_value.
        elem E X.
        """
      end

    assert {:aborted, _} = result
    :ok
  end

  example members_of_empty_mapset_is_empty_list() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new mapset_value #{elems => []} Empty.
        members Empty Elems.
        """
      end

    assert Map.get(bindings, :"$Elems") == []
    :ok
  end

  example members_of_mapset_is_its_elems() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new mapset_value #{elems => [4, 7]} S.
        members S Elems.
        """
      end

    assert Enum.sort(Map.get(bindings, :"$Elems")) == [4, 7]
    :ok
  end

  example members_constructs_a_canonical_mapset_from_a_member_list() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        members S [3, 1, 2, 1].
        """
      end

    assert Map.get(bindings, :"$S") == %{
             class: :mapset_value,
             elems: %{1 => true, 2 => true, 3 => true}
           }

    :ok
  end

  example intersection_of_overlapping_mapsets_produces_a_mapset() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new mapset_value #{elems => [3, 4]} S1.
        new mapset_value #{elems => [3, 5]} S2.
        intersection S1 S2 I.
        """
      end

    assert Map.get(bindings, :"$I") == %{class: :mapset_value, elems: %{3 => true}}
    :ok
  end

  example intersection_of_disjoint_mapsets_is_empty() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new mapset_value #{elems => [4]} S1.
        new mapset_value #{elems => [7]} S2.
        intersection S1 S2 I.
        """
      end

    assert Map.get(bindings, :"$I") == %{class: :mapset_value, elems: %{}}
    :ok
  end
end
