defmodule Examples.ALResidualConstraints do
  @moduledoc "I exercise residual constraint composition and answer projection."

  use ExExample
  use AL
  import ExUnit.Assertions

  example copy_term_returns_constraints_as_goals() do
    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        copy_term [a, X] Plain PlainGoals.
        = Plain [_, b].
        dif Y 1, copy_term Y DifCopy DifGoals, variant DifGoals [(dif DifCopy 1)].
        map_get M k _V, copy_term M KeyCopy KeyGoals, variant KeyGoals [(map_get KeyCopy k _Value)].
        functor F _Name _Args, copy_term F FunctorCopy FunctorGoals,
        variant FunctorGoals [(functor FunctorCopy _CopyName _CopyArgs)].
        in_domain D [1, 2, 3], copy_term D DomainCopy DomainGoals,
        variant DomainGoals [(in_domain DomainCopy [1, 2, 3])].
        < L 5, copy_term L BoundCopy BoundGoals, variant BoundGoals [(<= BoundCopy 4)].
        = S (+ T 1), copy_term [S, T] [CopyS, CopyT] ArithGoals,
        variant ArithGoals [(= (+ CopyS (* -1 CopyT)) 1)].
        freeze Fz {= Fz 1}, copy_term Fz FrozenCopy FrozenGoals, variant FrozenGoals [(= FrozenCopy 1)].
        = Fz 1.
        copy_term (+ 1 2) Expression ExpressionGoals.
        """,
        branch: Examples.Support.branch()
      )

    assert AL.Var.var?(bindings["$X"])
    assert bindings["$Plain"] == [:a, :b]
    assert bindings["$PlainGoals"] == []
    assert bindings["$Expression"] == %AL.Goal.Compound{name: :+, args: [1, 2]}
    assert bindings["$ExpressionGoals"] == []
  end

  example result_separates_bindings_from_constraints() do
    {:atomic, {bindings, constraints, _}} =
      run(
        ~S"""
        in_domain Value [1, 2, 3].
        dif Value 2.
        """,
        branch: Examples.Support.branch()
      )

    value = bindings["$Value"]
    assert AL.Var.var?(value)
    assert Enum.sort(constraints[AL.Var.key(value)].domain) == [1, 2, 3]
    assert constraints[AL.Var.key(value)].dif == [2]
    refute Map.has_key?(bindings, "$constraints")
  end

  example aliasing_merges_constraint_sets_before_projection() do
    {:atomic, {bindings, constraints, _}} =
      run(
        ~S"""
        in_domain Left [1, 2, 3].
        dif Left 3.
        in_domain Right [2, 3, 4].
        = Left Right.
        """,
        branch: Examples.Support.branch()
      )

    representative = bindings["$Left"]
    assert bindings["$Right"] == representative
    assert Enum.sort(constraints[AL.Var.key(representative)].domain) == [2, 3]
    assert constraints[AL.Var.key(representative)].dif == [3]
  end

  example isa_and_explicit_domains_narrow_independently_of_posting_order() do
    {:atomic, {first_bindings, first_constraints, _}} =
      run(
        ~S"""
        isa Value number.
        in_domain Value [1, not_a_number, 2].
        """,
        branch: Examples.Support.branch()
      )

    {:atomic, {second_bindings, second_constraints, _}} =
      run(
        ~S"""
        in_domain Value [1, not_a_number, 2].
        isa Value number.
        """,
        branch: Examples.Support.branch()
      )

    first = first_bindings["$Value"]
    second = second_bindings["$Value"]

    assert Enum.sort(first_constraints[AL.Var.key(first)].domain) == [1, 2]
    assert Enum.sort(second_constraints[AL.Var.key(second)].domain) == [1, 2]
    assert :number in first_constraints[AL.Var.key(first)].isa
    assert :number in second_constraints[AL.Var.key(second)].isa
  end

  example grounding_removes_satisfied_residual_constraints() do
    {:atomic, {bindings, constraints, _}} =
      run(
        ~S"""
        in_domain Value [1, 2].
        dif Value 2.
        = Value 1.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Value"] == 1
    assert constraints == %{}
  end

  example failed_alternatives_do_not_leak_constraints() do
    {:atomic, {bindings, constraints, _}} =
      run(
        ~S"""
        {in_domain Value [1, 2], = Value 9} ; in_domain Value [3, 4].
        """,
        branch: Examples.Support.branch()
      )

    value = bindings["$Value"]
    assert Enum.sort(constraints[AL.Var.key(value)].domain) == [3, 4]
  end

  example findall_copies_each_answers_constraint_graph() do
    {:atomic, {bindings, constraints, _}} =
      run(
        ~S"""
        findall Value Values (in_domain Value [1, 2] ; in_domain Value [3, 4]).
        """,
        branch: Examples.Support.branch()
      )

    [first, second] = bindings["$Values"]
    refute first == second

    domains =
      [constraints[AL.Var.key(first)].domain, constraints[AL.Var.key(second)].domain]
      |> Enum.map(&Enum.sort/1)
      |> MapSet.new()

    assert domains == MapSet.new([[1, 2], [3, 4]])
  end

  example copied_arithmetic_relations_reference_the_collected_variables() do
    {:atomic, {bindings, constraints, _}} =
      run(
        ~S"""
        findall [Left, Right] Answers {> Left 0, > Right 0, = (+ Left Right) 10}.
        """,
        branch: Examples.Support.branch()
      )

    [[left, right]] = bindings["$Answers"]
    [relation] = constraints.relations

    assert relation.op == :=
    assert relation.value == 10
    assert relation.terms[left] == 1
    assert relation.terms[right] == 1
  end

  example residual_dispatch_and_slot_constraints_share_one_graph() do
    {:atomic, {bindings, constraints, _}} =
      run(
        ~S"""
        @constraint_record
        #{super => value, ivars => [#{domain => [a, b], name => kind}]}.

        constraint_record >> constraint_probe
        | _Self ok |.

        constraint_probe Record ok.
        get Record kind Kind.
        """,
        branch: Examples.Support.branch()
      )

    record = bindings["$Record"]
    kind = bindings["$Kind"]

    assert constraints[AL.Var.key(record)].slots.kind == kind

    assert MapSet.new(constraints[AL.Var.key(record)].dispatch) ==
             MapSet.new([
               %{provider: :constraint_record, selector: :constraint_probe},
               %{provider: :object, selector: :get}
             ])

    assert Enum.sort(constraints[AL.Var.key(kind)].domain) == [:a, :b]
  end

  example open_class_relations_are_public_constraints() do
    {:atomic, {bindings, constraints, _}} =
      run(
        ~S"""
        class Object ExactClass.
        """,
        branch: Examples.Support.branch()
      )

    object = bindings["$Object"]
    exact_class = bindings["$ExactClass"]

    assert constraints[AL.Var.key(object)].class == [exact_class]
    refute Map.has_key?(constraints, exact_class)
  end

  example open_isa_relations_are_public_constraints() do
    {:atomic, {bindings, constraints, _}} =
      run(
        ~S"""
        isa Object Ancestor.
        """,
        branch: Examples.Support.branch()
      )

    object = bindings["$Object"]
    ancestor = bindings["$Ancestor"]

    assert constraints[AL.Var.key(object)].isa == [ancestor]
    refute Map.has_key?(constraints, ancestor)
  end

  example open_super_relations_are_visible_from_both_sides() do
    {:atomic, {bindings, constraints, _}} =
      run(
        ~S"""
        super Subclass Superclass.
        """,
        branch: Examples.Support.branch()
      )

    subclass = bindings["$Subclass"]
    superclass = bindings["$Superclass"]

    assert constraints[AL.Var.key(subclass)].super == superclass
    assert constraints[AL.Var.key(superclass)].subclass == subclass
  end

  example open_slot_relations_include_the_value_in_the_constraint_graph() do
    {:atomic, {bindings, constraints, _}} =
      run(
        ~S"""
        slot Object title Value.
        """,
        branch: Examples.Support.branch()
      )

    object = bindings["$Object"]
    value = bindings["$Value"]

    assert constraints[AL.Var.key(object)].slots.title == value
    assert constraints[AL.Var.key(value)].slot_of.title == object
  end
end
