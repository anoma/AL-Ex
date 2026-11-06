defmodule AL.JAM.ChoiceTest do
  use ExUnit.Case, async: true

  alias AL.JAM.{Execution, Frame, Machine, Trace}

  test "choice followed by a jump retains answer order and saved live registers" do
    for live <- [[0, 1], [0, 1, 2]] do
      frame = choice_frame(live)
      output = elem(frame.slots, 1)

      assert {:budget_exhausted, %Frame{pc: 1}, execution} =
               Machine.resume(frame, AL.Branch.head(), 0)

      assert %Execution{steps: 1, choices: [%Frame{pc: 2, slots: saved}]} = execution
      assert elem(saved, 0) == :saved
      assert elem(saved, 1) == output
      assert elem(saved, 2) == if(2 in live, do: :unused, else: nil)

      assert {:ok, store, execution} = Machine.resume(frame, AL.Branch.head(), 100)
      assert AL.Var.subst(output, store) == :first
      assert execution.steps == 4
      assert {:ok, store, execution} = Machine.retry(execution)
      assert AL.Var.subst(output, store) == :saved
      assert execution.steps == 7
      assert {:failed, nil, %Execution{choices: []}} = Machine.retry(execution)
    end
  end

  test "choice execution agrees with instruction tracing at every budget boundary" do
    frame = choice_frame([0, 1])
    ordinary = put_elem(frame.code, 0, {:try, 2, [0, 1]})

    transfer_code =
      ordinary
      |> put_elem(1, {:jump, 4, [{0, {:constant, :transferred}}]})
      |> put_elem(4, :pass)

    frames = [
      frame,
      %{frame | code: transfer_code},
      %{frame | code: put_elem(ordinary, 1, :fail)},
      %Frame{descriptor: :test, code: {{:try, 1, []}}, slots: {}, store: %{}}
    ]

    for frame <- frames, budget <- 0..8 do
      results = outcomes(Machine.resume(frame, AL.Branch.head(), budget))

      {traced, _} =
        Trace.run(AL.Trace.new(MapSet.new([:vm])), fn ->
          outcomes(Machine.resume(frame, AL.Branch.head(), budget))
        end)

      assert results == traced
    end
  end

  test "fused choices retain source goals and both relocation targets" do
    frame = choice_frame([0, 1])
    ordinary = %{frame | code: put_elem(frame.code, 0, {:try, 2, [0, 1]})}

    assert Frame.pending_goals(frame) == Frame.pending_goals(ordinary)

    {code, _} =
      AL.JAM.IR.Code.assemble([
        {:try, :alternative, []},
        {:label, :jump},
        {:jump, :done, []},
        {:label, :alternative},
        {:jump, :jump, []},
        {:label, :done}
      ])

    assert {:try, 2, [], 3} = elem(code, 0)
    assert {:jump, 3, []} = elem(code, 1)
    assert {:jump, 1, []} = elem(code, 2)
    assert AL.JAM.IR.Code.map_targets(elem(code, 0), &(&1 + 10)) == {:try, 12, [], 13}
  end

  test "instruction tracing retains the jump and each alternative" do
    frame = choice_frame([0, 1])

    {_, trace} =
      Trace.run(AL.Trace.new(MapSet.new([:vm])), fn ->
        outcomes(Machine.resume(frame, AL.Branch.head(), 100))
      end)

    positions =
      for %{payload: {:instruction, %{pc: pc}}} <- Enum.reverse(trace.events), do: pc

    assert positions == [0, 1, 4, 5, 2, 3]
  end

  test "suspended goals wake independently on each choice" do
    frame = choice_frame([0, 1])
    output = elem(frame.slots, 1)
    observed = {:"$var", "Observed"}
    wake = {:test, {{:eq, {:register, 0}, {:register, 1}}}, {observed, output}, nil}
    frame = %{frame | pending: AL.JAM.Suspension.park(%{}, [output], [wake])}

    results = outcomes(Machine.resume(frame, AL.Branch.head(), 100))
    stores = for {:ok, store, _} <- results, do: store

    assert Enum.map(stores, &AL.Var.subst([output, observed], &1)) == [
             [:first, :first],
             [:saved, :saved]
           ]

    for flags <- [[:vm], [:goals], [:domino]] do
      {traced, _} =
        Trace.run(AL.Trace.new(MapSet.new(flags)), fn ->
          outcomes(Machine.resume(frame, AL.Branch.head(), 100))
        end)

      assert traced == results
    end
  end

  defp choice_frame(live) do
    {code, _} =
      AL.JAM.IR.Code.assemble([
        {:try, :alternative, live},
        {:jump, :first, []},
        {:label, :alternative},
        {:eq, {:register, 1}, {:register, 0}},
        {:jump, :done, []},
        {:label, :first},
        {:move, 0, {:constant, :first}},
        {:eq, {:register, 1}, {:register, 0}},
        {:label, :done}
      ])

    %Frame{
      descriptor: :test,
      code: code,
      slots: {:saved, {:"$var", "Output"}, :unused},
      store: %{}
    }
  end

  defp outcomes({:ok, _, execution} = result),
    do: [result | outcomes(Machine.retry(execution))]

  defp outcomes({:budget_exhausted, frame, execution} = result),
    do: [result | outcomes(Machine.resume(frame, %{execution | budget: 100}))]

  defp outcomes(result), do: [result]
end
