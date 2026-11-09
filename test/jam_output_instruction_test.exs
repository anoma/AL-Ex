defmodule AL.JAM.OutputInstructionTest do
  use ExUnit.Case, async: true

  alias AL.JAM.{Arithmetic, Frame, Goals, Instruction, Machine, Operand, Trace}
  alias AL.Var

  @output {:"$var", "Output"}
  @destination {:"$var", "Destination"}
  @input {:"$var", "Input"}
  @key {:"$var", "Key"}

  test "direct equality preserves both operand orders, aliases and arithmetic fallback" do
    expression = %AL.Goal.Compound{name: :+, args: [@input, 1]}

    for name <- [:eq, :unify_structural],
        side <- [:left, :right],
        source <- [@input, %{a: @input}, expression],
        budget <- [0, 1, 100] do
      input = Operand.compile(source, %{@input => 1})

      operation =
        case side do
          :left -> {name, {:register, 0}, input}
          :right -> {name, input, {:register, 0}}
        end

      direct = operation |> Instruction.into(0) |> Arithmetic.select()
      suffix = [{:eq, {:register, 1}, {:constant, 7}}]

      expected =
        if name == :eq and source == expression,
          do: 8,
          else: Var.subst(source, %{@input => 7})

      assert answers(direct, {nil, @input}, suffix, budget) == [expected]
      assert answers(operation, {@destination, @input}, suffix, budget) == [expected]
      assert Trace.semantic_operation(direct) == operation

      assert Goals.instruction(direct, {@destination, @input}) ==
               Goals.instruction(operation, {@destination, @input})
    end
  end

  test "structural outputs preserve map-key collisions across later bindings" do
    first = Var.var("A")
    second = Var.var("Z")
    map = %{first => :first, second => :second}
    operation = {:unify_structural, {:register, 0}, {:register, 1}}

    for {bound, open} <- [{first, second}, {second, first}],
        source <- [map, [map], %{nested: map}],
        budget <- [0, 1, 100] do
      store = %{bound => :slot}
      suffix = [{:eq, {:constant, open}, {:constant, :slot}}]
      expected = answers(operation, {@destination, source}, suffix, budget, store)

      assert answers(Instruction.into(operation, 0), {nil, source}, suffix, budget, store) ==
               expected
    end
  end

  test "direct field reads retain alternatives, aliases, missing fields and nil values" do
    for operation <- [
          {:map_get_into, 0, {:register, 1}, {:register, 2}},
          {:slot_get_into, 0, {:register, 1}, {:register, 2}, {:constant, :stored}}
        ],
        {map, key, expected} <- [
          {%{a: nil, b: false}, @key, [nil, false]},
          {%{a: @input}, :a, [7]},
          {%{a: 1}, :missing, []}
        ],
        destination <- [@destination, nil] do
      slots = {destination, map, key}
      suffix = [{:eq, {:constant, @input}, {:constant, 7}}]
      actual = answers(operation, slots, suffix)
      assert Enum.sort(actual) == Enum.sort(expected)

      assert actual ==
               answers(Instruction.general(operation), {@destination, map, key}, suffix)
    end
  end

  test "suspended map reads retain their output when inputs arrive later" do
    operation = {:map_get_into, 0, {:register, 1}, {:register, 2}}

    suffix = [
      {:eq, {:register, 1}, {:constant, %{a: 7, b: 8}}},
      {:eq, {:register, 2}, {:constant, :a}}
    ]

    for budget <- [0, 1, 100],
        destination <- [nil, @destination],
        suffix <- [suffix, Enum.reverse(suffix)] do
      assert answers(operation, {destination, @input, @key}, suffix, budget) == [7]
    end
  end

  test "wildcard fields leave a logical output rather than a nil value" do
    for operation <- [
          {:map_get_into, 0, {:constant, %{a: {:"$var", "_"}}}, {:constant, :a}},
          {:slot_get_into, 0, {:constant, %{a: {:"$var", "_"}}}, {:constant, :a},
           {:constant, :stored}}
        ] do
      assert answers(operation, {nil}, [{:eq, {:register, 0}, {:constant, :bound}}]) == [:bound]
    end
  end

  test "primitive output modes write uninitialised registers in both directions" do
    for {name, position, input, expected} <- [
          {:string_codes, 0, [955, 128_512], "λ😀"},
          {:string_codes, 1, "λ😀", [955, 128_512]},
          {:atom_string, 0, "λ😀", :"λ😀"},
          {:atom_string, 1, nil, "nil"},
          {:map_pairs, 0, [[:a, @input]], %{a: 7}},
          {:map_pairs, 1, %{a: @input}, [[:a, 7]]}
        ],
        input_operand <- [{:register, 1}, {:constant, input}],
        destination <- [nil, @destination] do
      arguments = List.insert_at([input_operand], position, {:register, 0})
      operation = Instruction.into({:primitive, name, arguments}, 0)
      suffix = [{:eq, {:constant, @input}, {:constant, 7}}]

      assert answers(operation, {destination, input}, suffix) == [expected]
      assert answers(Instruction.general(operation), {@destination, input}, suffix) == [expected]
    end
  end

  test "lazy primitive outputs preserve suspension, aliases and conflicts" do
    for {name, position, input, expected, conflict} <- [
          {:string_codes, 0, [97], "a", "b"},
          {:string_codes, 1, "a", [97], [98]},
          {:atom_string, 0, "a", :a, :b},
          {:atom_string, 1, :a, "a", "b"},
          {:map_pairs, 0, [[:a, 7]], %{a: 7}, %{a: 8}},
          {:map_pairs, 1, %{a: 7}, [[:a, 7]], [[:a, 8]]}
        ],
        budget <- [0, 1, 100] do
      arguments = List.insert_at([{:register, 1}], position, {:register, 0})
      operation = Instruction.into({:primitive, name, arguments}, 0)
      suffix = [{:eq, {:register, 1}, {:constant, input}}]
      assert answers(operation, {nil, @input}, suffix, budget) == [expected]

      conflicting = [{:eq, {:register, 0}, {:constant, conflict}} | suffix]
      assert answers(operation, {nil, @input}, conflicting, budget) == []
    end
  end

  test "invalid primitive inputs still fail through the ordinary relation" do
    for {name, position, input} <- [
          {:string_codes, 0, [0xD800]},
          {:string_codes, 1, <<255>>},
          {:atom_string, 0, <<255>>},
          {:atom_string, 1, 42},
          {:map_pairs, 0, [[:a, 1], [:a, 2]]},
          {:map_pairs, 1, [:a, 1]}
        ] do
      arguments = List.insert_at([{:constant, input}], position, {:register, 0})
      operation = Instruction.into({:primitive, name, arguments}, 0)
      assert answers(operation, {nil}, []) == []
      assert answers(Instruction.general(operation), {@destination}, []) == []
    end
  end

  test "an open map retains its key constraint until the map is bound" do
    operation = {:map_get_into, 0, {:register, 1}, {:constant, :a}}

    for {map, expected} <- [{%{a: 7, b: 8}, [7]}, {%{b: 8}, []}],
        destination <- [nil, @destination] do
      suffix = [{:unify_structural, {:register, 1}, {:constant, map}}]
      assert answers(operation, {destination, @input}, suffix) == expected

      assert answers(Instruction.general(operation), {@destination, @input}, suffix) == expected
    end
  end

  test "direct map construction preserves shared keys and values across budget resumes" do
    operation =
      {:map_put_into, 0, {:constant, %{a: @input}}, {:constant, @key}, {:constant, @input}}

    suffix = [
      {:eq, {:constant, @key}, {:constant, :b}},
      {:eq, {:constant, @input}, {:constant, 7}}
    ]

    for budget <- [0, 1, 100] do
      assert answers(operation, {@destination}, suffix, budget) == [%{a: 7, b: 7}]

      assert answers(Instruction.general(operation), {@destination}, suffix, budget) == [
               %{a: 7, b: 7}
             ]
    end
  end

  test "direct instructions reconstruct the original goal and operand order" do
    slots = {@destination, @input, @key}

    operations = [
      {:eq, {:register, 0}, {:register, 1}},
      {:eq, {:register, 1}, {:register, 0}},
      {:unify_structural, {:register, 0}, {:register, 1}},
      {:unify_structural, {:register, 1}, {:register, 0}},
      {:map_get, {:register, 1}, {:register, 2}, {:register, 0}},
      {:slot_get, {:register, 1}, {:register, 2}, {:register, 0}, {:constant, :stored}},
      {:map_put, {:register, 1}, {:register, 2}, {:constant, :value}, {:register, 0}},
      {:primitive, :string_codes, [{:register, 0}, {:register, 1}]},
      {:primitive, :string_codes, [{:register, 1}, {:register, 0}]},
      {:primitive, :atom_string, [{:register, 0}, {:register, 1}]},
      {:primitive, :atom_string, [{:register, 1}, {:register, 0}]},
      {:primitive, :map_pairs, [{:register, 0}, {:register, 1}]},
      {:primitive, :map_pairs, [{:register, 1}, {:register, 0}]}
    ]

    for operation <- operations do
      direct = Instruction.into(operation, 0)
      assert Trace.semantic_operation(direct) == operation
      assert Goals.instruction(direct, slots) == Goals.instruction(operation, slots)
      assert Trace.Format.instruction(direct) =~ Atom.to_string(elem(direct, 0))
    end
  end

  defp answers(operation, slots, suffix, budget \\ 100, store \\ %{}) do
    frame = %Frame{
      descriptor: :test,
      slots: slots,
      store: store,
      code:
        List.to_tuple(
          [operation | suffix] ++
            [{:unify_structural, {:constant, @output}, {:register, 0}}]
        )
    }

    collect(Machine.resume(frame, AL.Branch.head(), budget))
  end

  defp collect({:budget_exhausted, frame, execution}) do
    execution = %{execution | budget: execution.steps + 1}

    if frame,
      do: collect(Machine.resume(frame, execution)),
      else: collect(Machine.retry(execution))
  end

  defp collect({:ok, store, execution}),
    do: [Var.subst(@output, store) | collect(Machine.retry(execution))]

  defp collect({:failed, _, _}), do: []
end
