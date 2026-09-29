defmodule Examples.ALInDomain do
  @moduledoc """
  `in_domain/2` -- "this var is one of these", a real constraint on the var
  itself (narrows via intersection across repeated posts, checked at bind
  time like dif/isa/bounds), not a class with a :domain method. No class,
  no dispatch, works the same on a ground or open var either direction.
  Domain order isn't preserved (stored as a MapSet for O(1) membership and
  set intersection), unlike a class's own :domain method list -- examples
  here check membership/sets, not a specific first-labeled value.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example in_domain_labels_every_candidate_exactly_once() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        in_domain X [a, b, c].
        findall X All {label X}.
        """
      end

    assert Enum.sort(Map.get(bindings, :"$All")) == [:a, :b, :c]
    :ok
  end

  example two_in_domain_calls_narrow_via_intersection() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        in_domain Y [a, b, c, d].
        in_domain Y [c, d, e].
        findall Y All {label Y}.
        """
      end

    assert Enum.sort(Map.get(bindings, :"$All")) == [:c, :d]
    :ok
  end

  example an_empty_intersection_fails_immediately() do
    {:aborted, _trace} =
      run branch: Examples.Support.branch() do
        ~AL"""
        in_domain Y [a, b].
        in_domain Y [c, d].
        """
      end

    :ok
  end

  example a_domain_narrowed_to_one_value_auto_binds() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        in_domain Z [only_one].
        """
      end

    assert Map.get(bindings, :"$Z") == :only_one
    :ok
  end

  # dif rules out a candidate the same way it would for any other bind --
  # no special interaction code needed, the ordinary bind-time check does it.
  example dif_excludes_a_candidate_at_label_time() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        dif V a.
        in_domain V [a, b].
        label V.
        """
      end

    assert Map.get(bindings, :"$V") == :b
    :ok
  end

  example unify_against_a_value_outside_the_domain_fails() do
    {:aborted, reason} =
      run branch: Examples.Support.branch() do
        ~AL"""
        in_domain W [a, b].
        W = not_in_set.
        """
      end

    assert {:constraint_violated, {:domain, domain}} = reason.reason
    assert Enum.sort(domain) == [:a, :b]
    :ok
  end

  example ground_membership_check_needs_no_constraint_at_all() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        in_domain a [a, b, c].
        """
      end

    {:aborted, _trace} =
      run branch: Examples.Support.branch() do
        ~AL"""
        in_domain z [a, b, c].
        """
      end

    :ok
  end
end
