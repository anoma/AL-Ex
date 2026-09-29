defmodule Examples.ALResidualConstraints do
  @moduledoc "I exercise residual constraint composition and answer projection."

  use ExExample
  use AL
  import ExUnit.Assertions

  example result_separates_bindings_from_constraints() do
    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        in_domain Value [1, 2, 3].
        dif Value 2.
        """
      end

    value = bindings[:"$Value"]
    assert AL.Var.var?(value)
    assert Enum.sort(constraints[value].domain) == [1, 2, 3]
    assert constraints[value].dif == [2]
    refute Map.has_key?(bindings, :"$constraints")
  end

  example aliasing_merges_constraint_sets_before_projection() do
    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        in_domain Left [1, 2, 3].
        dif Left 3.
        in_domain Right [2, 3, 4].
        Left = Right.
        """
      end

    representative = bindings[:"$Left"]
    assert bindings[:"$Right"] == representative
    assert Enum.sort(constraints[representative].domain) == [2, 3]
    assert constraints[representative].dif == [3]
  end

  example isa_and_explicit_domains_narrow_independently_of_posting_order() do
    {:atomic, {first_bindings, first_constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        isa Value number.
        in_domain Value [1, not_a_number, 2].
        """
      end

    {:atomic, {second_bindings, second_constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        in_domain Value [1, not_a_number, 2].
        isa Value number.
        """
      end

    first = first_bindings[:"$Value"]
    second = second_bindings[:"$Value"]

    assert Enum.sort(first_constraints[first].domain) == [1, 2]
    assert Enum.sort(second_constraints[second].domain) == [1, 2]
    assert :number in first_constraints[first].isa
    assert :number in second_constraints[second].isa
  end

  example grounding_removes_satisfied_residual_constraints() do
    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        in_domain Value [1, 2].
        dif Value 2.
        Value = 1.
        """
      end

    assert bindings[:"$Value"] == 1
    assert constraints == %{}
  end

  example failed_alternatives_do_not_leak_constraints() do
    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        {in_domain Value [1, 2], Value = 9} ; in_domain Value [3, 4].
        """
      end

    value = bindings[:"$Value"]
    assert Enum.sort(constraints[value].domain) == [3, 4]
  end

  example findall_copies_each_answers_constraint_graph() do
    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall Value Values {in_domain Value [1, 2] ; in_domain Value [3, 4]}.
        """
      end

    [first, second] = bindings[:"$Values"]
    refute first == second

    domains =
      [constraints[first].domain, constraints[second].domain]
      |> Enum.map(&Enum.sort/1)
      |> MapSet.new()

    assert domains == MapSet.new([[1, 2], [3, 4]])
  end

  example copied_arithmetic_relations_reference_the_collected_variables() do
    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall [Left, Right] Answers {Left > 0, Right > 0, Left + Right = 10}.
        """
      end

    [[left, right]] = bindings[:"$Answers"]
    [relation] = constraints.relations

    assert relation.op == :=
    assert relation.value == 10
    assert relation.terms[left] == 1
    assert relation.terms[right] == 1
  end

  example residual_dispatch_and_slot_constraints_share_one_graph() do
    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @constraint_record
        #{super: value, ivars: [#{domain: [a, b], name: kind}]}.

        constraint_record >> constraint_probe
        | _Self ok |.

        constraint_probe Record ok.
        get Record kind Kind.
        """
      end

    record = bindings[:"$Record"]
    kind = bindings[:"$Kind"]

    assert constraints[record].slots.kind == kind

    assert MapSet.new(constraints[record].dispatch) ==
             MapSet.new([
               %{provider: :constraint_record, selector: :constraint_probe},
               %{provider: :object, selector: :get}
             ])

    assert Enum.sort(constraints[kind].domain) == [:a, :b]
  end

  example open_class_relations_are_public_constraints() do
    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        class Object ExactClass.
        """
      end

    object = bindings[:"$Object"]
    exact_class = bindings[:"$ExactClass"]

    assert constraints[object].class == [exact_class]
    refute Map.has_key?(constraints, exact_class)
  end

  example open_isa_relations_are_public_constraints() do
    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        isa Object Ancestor.
        """
      end

    object = bindings[:"$Object"]
    ancestor = bindings[:"$Ancestor"]

    assert constraints[object].isa == [ancestor]
    refute Map.has_key?(constraints, ancestor)
  end

  example open_super_relations_are_visible_from_both_sides() do
    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        super Subclass Superclass.
        """
      end

    subclass = bindings[:"$Subclass"]
    superclass = bindings[:"$Superclass"]

    assert constraints[subclass].super == superclass
    assert constraints[superclass].subclass == subclass
  end

  example open_slot_relations_include_the_value_in_the_constraint_graph() do
    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        slot Object title Value.
        """
      end

    object = bindings[:"$Object"]
    value = bindings[:"$Value"]

    assert constraints[object].slots.title == value
    assert constraints[value].slot_of.title == object
  end
end
