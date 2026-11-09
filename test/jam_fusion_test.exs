defmodule AL.JAM.FusionTest do
  use ExUnit.Case, async: true
  alias AL.JAM.IR.{Normalize, Program, Selection, SlotBatch}
  alias Program.{Node, Choice, Condition}

  test "fusion examines a long sequence a linear number of times" do
    instructions = for bound <- 1..512, do: {:compare, :<, {:"$var", "Value"}, bound}
    program = Normalize.lower(instructions)
    visits = :counters.new(1, [])

    key = fn {:compare, _, value, _} ->
      :counters.add(visits, 1, 1)
      {:ok, value}
    end

    fused = Program.fuse_instructions(program, key, &{:group, &1})
    assert :counters.get(visits, 1) <= 2 * length(instructions)
    assert map_size(fused.nodes) == 2
    assert %Node{instruction: {:group, ^instructions}} = fused.nodes[fused.entry]
  end

  test "fusion respects branch entries, shared continuations and source order" do
    value = {:"$var", "Value"}
    lower = {:compare, :>=, value, 1}
    upper = {:compare, :<, value, 9}
    exclude = {:dif, value, 5}

    for control <- [
          %Choice{left: 20, right: 10, join: 40},
          %Condition{condition: 20, then: 10, otherwise: 40, join: 40}
        ] do
      program = %Program{
        entry: 70,
        nodes: %{
          70 => control,
          20 => %Node{instruction: lower, next: 60},
          60 => {:next, 30},
          30 => %Node{instruction: upper, next: 40},
          10 => %Node{instruction: exclude, next: 40},
          40 => %Node{instruction: lower, next: 50},
          50 => %Node{instruction: upper, next: 0},
          0 => :return,
          99 => %Node{instruction: exclude, next: 99}
        }
      }

      selected = Selection.select(program)
      assert map_size(selected.nodes) == 5
      assert selected.nodes[70] == control
      assert selected.nodes[10] == program.nodes[10]

      assert %Node{instruction: {:numeric_tests, ^value, _, [^lower, ^upper]}, next: 40} =
               selected.nodes[20]

      assert %Node{instruction: {:numeric_tests, ^value, _, [^lower, ^upper]}, next: 0} =
               selected.nodes[40]
    end
  end

  test "fusion preserves a loop back to its entry" do
    value = {:"$var", "Value"}
    instructions = [{:compare, :>=, value, 1}, {:compare, :<, value, 9}]

    program = %Program{
      entry: 5,
      nodes: %{
        5 => %Node{instruction: hd(instructions), next: 2},
        2 => %Node{instruction: List.last(instructions), next: 5}
      }
    }

    selected = Selection.select(program)

    assert %{5 => %Node{instruction: {:numeric_tests, ^value, _, ^instructions}, next: 5}} =
             selected.nodes
  end

  test "slot batches retain repeated writes and stop at object changes" do
    instructions = [
      {:set_slot, :first, :a, 1},
      {:set_slot, :first, :a, 2},
      {:set_slot, :second, :a, 3},
      {:set_slot, :second, :b, 4},
      {:set_slot, :first, :b, 5}
    ]

    program = instructions |> Normalize.lower() |> SlotBatch.compile()

    assert Program.reduce(program, [], fn operation, acc -> acc ++ [operation] end) == [
             {:slot_batch, [{:first, :a, 1}, {:first, :a, 2}]},
             {:slot_batch, [{:second, :a, 3}, {:second, :b, 4}]},
             {:set_slot, :first, :b, 5}
           ]
  end
end
