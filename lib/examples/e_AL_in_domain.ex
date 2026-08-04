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
    {:atomic, {bindings, _}} =
      run branch: :examples do
        in_domain(x, [:a, :b, :c])
        findall(x, [label(x)], all)
      end

    assert Enum.sort(Map.get(bindings, :"$all")) == [:a, :b, :c]
    :ok
  end

  example two_in_domain_calls_narrow_via_intersection() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        in_domain(y, [:a, :b, :c, :d])
        in_domain(y, [:c, :d, :e])
        findall(y, [label(y)], all)
      end

    assert Enum.sort(Map.get(bindings, :"$all")) == [:c, :d]
    :ok
  end

  example an_empty_intersection_fails_immediately() do
    {:aborted, _trace} =
      run branch: :examples do
        in_domain(y, [:a, :b])
        in_domain(y, [:c, :d])
      end

    :ok
  end

  example a_domain_narrowed_to_one_value_auto_binds() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        in_domain(z, [:only_one])
      end

    assert Map.get(bindings, :"$z") == :only_one
    :ok
  end

  # dif rules out a candidate the same way it would for any other bind --
  # no special interaction code needed, the ordinary bind-time check does it.
  example dif_excludes_a_candidate_at_label_time() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        dif(v, :a)
        in_domain(v, [:a, :b])
        label(v)
      end

    assert Map.get(bindings, :"$v") == :b
    :ok
  end

  example unify_against_a_value_outside_the_domain_fails() do
    {:aborted, reason} =
      run branch: :examples do
        in_domain(w, [:a, :b])
        unify(w, :not_in_set)
      end

    assert {:constraint_violated, {:domain, domain}} = reason.reason
    assert Enum.sort(domain) == [:a, :b]
    :ok
  end

  example ground_membership_check_needs_no_constraint_at_all() do
    {:atomic, _} =
      run branch: :examples do
        in_domain(:a, [:a, :b, :c])
      end

    {:aborted, _trace} =
      run branch: :examples do
        in_domain(:z, [:a, :b, :c])
      end

    :ok
  end
end
