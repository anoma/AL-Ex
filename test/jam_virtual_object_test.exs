defmodule AL.JAM.VirtualObjectTest do
  use ExUnit.Case, async: true
  alias AL.{Goal, JAM, Var}
  alias AL.JAM.IR.{Program, Region}

  @output {:"$var", "Output"}
  @first {:"$var", "First"}
  @second {:"$var", "Second"}
  @field {:"$var", "Field"}

  defp put(map, key, value, result),
    do: %Goal.OApply{method_id: :vm_map_put, args: [map, key, value, result]}

  defp get(map, key, result),
    do: %Goal.OApply{method_id: :map_get, args: [map, key, result]}

  defp optimized(goals),
    do: goals |> Program.lower() |> Region.compile(MapSet.new([@output]))

  defp answers(program) do
    frame = program |> JAM.compile() |> JAM.with_store(%{})
    collect(JAM.resume(frame, AL.Branch.head(), 1000), [])
  end

  defp collect({:ok, store, _}, choices), do: [Var.subst(@output, store) | remaining(choices)]

  defp collect({:answers, store, more, _}, choices),
    do: [Var.subst(@output, store) | remaining(more ++ choices)]

  defp collect({:failed, _, _}, choices), do: remaining(choices)
  defp remaining([]), do: []

  defp remaining([choice | rest]),
    do: collect(JAM.resume(choice, AL.Branch.head(), 1000), rest)

  test "temporary value maps disappear while their field survives" do
    goals = [
      put(%{class: :point}, :x, 10, @first),
      put(@first, :y, 20, @second),
      get(@second, :x, @output)
    ]

    program = optimized(goals)
    assert answers(Program.lower(goals)) == [10]
    assert answers(program) == [10]
    frame = JAM.compile(program)

    assert Tuple.to_list(frame.code) == [
             {:unify_structural, {:register, 0}, {:constant, 10}},
             :progress
           ]
  end

  test "escaping values retain shared variables" do
    goals = [
      put(%{class: :point}, :x, @field, @first),
      put(@first, :y, @field, @output),
      %Goal.Eq{a: @field, b: 7}
    ]

    expected = [%{class: :point, x: 7, y: 7}]
    assert answers(Program.lower(goals)) == expected
    assert answers(optimized(goals)) == expected
  end

  test "arithmetic fields remain terms rather than being evaluated" do
    term = %Goal.Compound{name: :+, args: [1, 2]}
    goals = [put(%{}, :expression, term, @first), get(@first, :expression, @output)]
    assert answers(Program.lower(goals)) == [term]
    assert answers(optimized(goals)) == [term]
  end

  test "virtual values preserve alternatives and missing field failure" do
    goals = [
      %Goal.Or{or: [put(%{}, :x, 1, @first)], then: [put(%{}, :x, 2, @first)]},
      get(@first, :x, @output)
    ]

    assert answers(Program.lower(goals)) == [1, 2]
    assert answers(optimized(goals)) == [1, 2]
    assert answers(optimized([get(%{x: 1}, :missing, @output)])) == []
  end

  test "unknown keys retain relational enumeration" do
    goals = [get(%{x: 1, y: 2}, @field, @output)]
    assert Enum.sort(answers(Program.lower(goals))) == [1, 2]
    assert Enum.sort(answers(optimized(goals))) == [1, 2]
  end

  test "constraints on fields survive virtual updates" do
    for value <- [7, 8] do
      goals = [
        %Goal.Dif{a: @field, b: 7},
        put(%{}, :x, @field, @first),
        put(@first, :y, @field, @second),
        get(@second, :x, @output),
        %Goal.Eq{a: @field, b: value}
      ]

      assert answers(optimized(goals)) == answers(Program.lower(goals))
    end
  end

  test "variable map keys are not treated as a fixed shape" do
    goals = [
      put(%{@field => 1}, :x, 2, @first),
      %Goal.Eq{a: @field, b: :x},
      get(@first, :x, @output)
    ]

    assert answers(optimized(goals)) == answers(Program.lower(goals))
  end

  test "a call boundary retains the map needed by its callee" do
    goals = [
      put(%{class: :point}, :x, @field, @first),
      %Goal.Send{object: @first, method: :consume, args: [@output]}
    ]

    program = optimized(goals)

    assert {:call, %{kind: :send, name: :consume, args: [%{class: :point, x: @field}, [@output]]},
            _} =
             program.blocks[program.entry].exit

    assert MapSet.member?(Program.variables(program), @field)
  end
end
