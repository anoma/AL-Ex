defmodule Examples.ALResidualConstraints do
  @moduledoc "I exercise residual constraint composition and answer projection."

  use ExExample
  use AL
  import ExUnit.Assertions

  example result_separates_bindings_from_constraints() do
    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        in_domain(value, [1, 2, 3])
        dif(value, 2)
      end

    value = bindings[:"$value"]
    assert AL.Var.var?(value)
    assert Enum.sort(constraints[value].domain) == [1, 2, 3]
    assert constraints[value].dif == [2]
    refute Map.has_key?(bindings, :"$constraints")
  end

  example aliasing_merges_constraint_sets_before_projection() do
    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        in_domain(left, [1, 2, 3])
        dif(left, 3)
        in_domain(right, [2, 3, 4])
        left = right
      end

    representative = bindings[:"$left"]
    assert bindings[:"$right"] == representative
    assert Enum.sort(constraints[representative].domain) == [2, 3]
    assert constraints[representative].dif == [3]
  end

  example isa_and_explicit_domains_narrow_independently_of_posting_order() do
    {:atomic, {first_bindings, first_constraints, _}} =
      run branch: Examples.Support.branch() do
        isa(value, :number)
        in_domain(value, [1, :not_a_number, 2])
      end

    {:atomic, {second_bindings, second_constraints, _}} =
      run branch: Examples.Support.branch() do
        in_domain(value, [1, :not_a_number, 2])
        isa(value, :number)
      end

    first = first_bindings[:"$value"]
    second = second_bindings[:"$value"]

    assert Enum.sort(first_constraints[first].domain) == [1, 2]
    assert Enum.sort(second_constraints[second].domain) == [1, 2]
    assert :number in first_constraints[first].isa
    assert :number in second_constraints[second].isa
  end

  example grounding_removes_satisfied_residual_constraints() do
    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        in_domain(value, [1, 2])
        dif(value, 2)
        value = 1
      end

    assert bindings[:"$value"] == 1
    assert constraints == %{}
  end

  example failed_alternatives_do_not_leak_constraints() do
    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        alternative(
          [in_domain(value, [1, 2]), value = 9],
          [in_domain(value, [3, 4])]
        )
      end

    value = bindings[:"$value"]
    assert Enum.sort(constraints[value].domain) == [3, 4]
  end

  example findall_copies_each_answers_constraint_graph() do
    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        findall(value, values) do
          alternative([in_domain(value, [1, 2])], [in_domain(value, [3, 4])])
        end
      end

    [first, second] = bindings[:"$values"]
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
        findall([left, right], answers) do
          left > 0
          right > 0
          left + right = 10
        end
      end

    [[left, right]] = bindings[:"$answers"]
    [relation] = constraints.relations

    assert relation.op == :=
    assert relation.value == 10
    assert relation.terms[left] == 1
    assert relation.terms[right] == 1
  end

  example residual_dispatch_and_slot_constraints_share_one_graph() do
    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        defclass :constraint_record,
          super: :value,
          ivars: [%{name: :kind, domain: [:a, :b]}],
          redef: true do
          defmethod(:constraint_probe, [_self, :ok])
        end

        constraint_probe(record, :ok)
        get(record, :kind, kind)
      end

    record = bindings[:"$record"]
    kind = bindings[:"$kind"]

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
        class(object, exact_class)
      end

    object = bindings[:"$object"]
    exact_class = bindings[:"$exact_class"]

    assert constraints[object].class == [exact_class]
    refute Map.has_key?(constraints, exact_class)
  end

  example open_isa_relations_are_public_constraints() do
    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        isa(object, ancestor)
      end

    object = bindings[:"$object"]
    ancestor = bindings[:"$ancestor"]

    assert constraints[object].isa == [ancestor]
    refute Map.has_key?(constraints, ancestor)
  end

  example open_super_relations_are_visible_from_both_sides() do
    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        super(subclass, superclass)
      end

    subclass = bindings[:"$subclass"]
    superclass = bindings[:"$superclass"]

    assert constraints[subclass].super == superclass
    assert constraints[superclass].subclass == subclass
  end

  example open_slot_relations_include_the_value_in_the_constraint_graph() do
    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        slot(object, :title, value)
      end

    object = bindings[:"$object"]
    value = bindings[:"$value"]

    assert constraints[object].slots.title == value
    assert constraints[value].slot_of.title == object
  end
end
