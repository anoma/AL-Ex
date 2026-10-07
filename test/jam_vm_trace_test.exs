defmodule AL.JAM.VMTraceTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  test "VM tracing retains optimized instructions and register snapshots", %{branch: branch} do
    assert {:atomic, {plain, _, _}} = AL.eval_source("count_to 0 3.", branch)
    assert {:atomic, {^plain, _, state}} = AL.eval_source("count_to 0 3.", branch, trace: [:vm])
    events = Enum.reverse(state.trace.events)
    assert Enum.all?(events, &match?(%AL.Trace.Event{kind: :vm}, &1))
    instructions = for %{payload: {:instruction, context}} <- events, do: context

    arithmetic =
      Enum.filter(instructions, &match?({:integer_arithmetic, _, _, _, _, _}, &1.instruction))

    assert length(arithmetic) == 3

    for [current, next] <- Enum.chunk_every(instructions, 2, 1, :discard),
        {:integer_arithmetic, :+, destination, left, right, _} <- [current.instruction] do
      assert current.frame == next.frame
      assert next.pc == current.pc + 1

      expected =
        AL.JAM.Operand.read(left, current.registers) +
          AL.JAM.Operand.read(right, current.registers)

      assert elem(next.registers, destination) == expected
    end

    output = capture_io(fn -> AL.Trace.render(events) end)
    assert output =~ "integer_arithmetic"
    assert output =~ "registers before:"
  end

  test "goals and instruction flags retain distinct event families", %{branch: branch} do
    assert {:atomic, {_, _, goals}} = AL.eval_source("pass.", branch, trace: [:goals])

    assert Enum.any?(
             goals.trace.events,
             &match?(%AL.Trace.Event{kind: :goals, payload: %AL.Goal.Pass{}}, &1)
           )

    assert Enum.all?(goals.trace.events, &(&1.kind == :goals))

    assert {:atomic, {_, _, both}} = AL.eval_source("pass.", branch, trace: [:goals, :vm])
    assert Enum.any?(both.trace.events, &(&1.kind == :goals))

    assert Enum.any?(
             both.trace.events,
             &match?(
               %AL.Trace.Event{kind: :vm, payload: {:instruction, %{instruction: :pass}}},
               &1
             )
           )
  end

  test "instruction tracing includes collection branches and failed transactions", %{
    branch: branch
  } do
    assert {:atomic, {%{"$Answers" => [:a, :b]}, _, state}} =
             AL.eval_source("findall X Answers {= X a ; = X b}.", branch, trace: [:vm])

    assert Enum.any?(
             state.trace.events,
             &match?(%{payload: {:instruction, %{instruction: {:branch, _, _}}}}, &1)
           )

    assert {:aborted, reason} = AL.eval_source("fail.", branch, trace: [:vm])
    assert Enum.any?(reason.trace, &match?(%{payload: {:instruction, %{instruction: :fail}}}, &1))
  end

  test "integer guard fallback is visible without disabling the instruction", %{branch: branch} do
    assert {:atomic, _} =
             AL.eval_source(
               ~S"""
               @vm_trace_probe #{super => value}.
               vm_trace_probe >> increment
               | _Self Input Output |
               = Temp (+ Input 1),
               = Input 4,
               = Output Temp.
               """,
               branch
             )

    assert {:atomic, {%{"$X" => 4, "$Y" => 5}, _, state}} =
             AL.eval_source(~S"increment #{class => vm_trace_probe} X Y.", branch, trace: [:vm])

    assert Enum.any?(
             state.trace.events,
             &match?(%{payload: {:fallback, %{instruction: {:local, _, _}}}}, &1)
           )
  end
end
