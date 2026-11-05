defmodule AL.JAM.OpenDispatchTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               @open_left #{super => value}.
               @open_right #{super => value}.

               open_left >> open_cut
               | _Self left |
               cut.
               open_left >> open_cut
               | _Self left_unreachable |.
               open_right >> open_cut
               | _Self right |
               cut.
               open_right >> open_cut
               | _Self right_unreachable |.

               open_left >> open_edit
               | _Self open_left old |.
               open_right >> open_edit
               | _Self open_right old |.

               open_left >> open_pick
               | _Self left |.
               open_right >> open_pick
               | _Self right |.

               @open_child #{super => open_left}.
               open_child >> open_pick
               | Self [child, Parent] |
               freeze Gate {call_next_method Self Parent},
               = Gate ready.

               new object #{name => open_singleton} Singleton.
               defmethod Singleton open_single [Self, one] {}.
               defmethod Singleton open_single [Self, two] {}.
               """,
               branch
             )

    %{branch: branch}
  end

  for trace <- [[], [:vm], [:goals], [:domino], [:goals, :domino, :vm]] do
    @trace trace

    test "cuts stay within each provider with #{inspect(trace)}", %{branch: branch} do
      assert %AL{result: {:atomic, {bindings, _, _}}} =
               AL.run("findall Value Values {open_cut Receiver Value}.", branch, trace: @trace)

      assert Enum.sort(bindings["$Values"]) == [:left, :right]
    end

    test "untried providers see method edits with #{inspect(trace)}", %{branch: branch} do
      assert %AL{result: {:atomic, {bindings, _, first}}} =
               AL.run("open_edit Receiver Owner Value.", branch, trace: @trace)

      assert bindings["$Value"] == :old
      assert AL.has_potential_solution?(first)
      other = if bindings["$Owner"] == :open_left, do: :open_right, else: :open_left

      assert %AL{result: {:atomic, _}} =
               AL.run(
                 """
                 defmethod Owner open_edit [Self, Owner, new] {}.
                 defmethod Entered open_edit [Self, Entered, unseen] {}.
                 """,
                 branch,
                 bindings: %{"Owner" => other, "Entered" => bindings["$Owner"]}
               )

      assert %AL{result: {:atomic, {bindings, _, second}}} = AL.next_solution(first)
      assert bindings["$Owner"] == other
      assert bindings["$Value"] == :old
      assert AL.has_potential_solution?(second)

      assert %AL{result: {:atomic, {bindings, _, third}}} = AL.next_solution(second)
      assert bindings["$Owner"] == other
      assert bindings["$Value"] == :new
      assert %AL{result: {:aborted, _}} = AL.next_solution(third)
    end

    test "late receivers and frozen next-method cursors agree with #{inspect(trace)}", %{
      branch: branch
    } do
      assert %AL{result: {:atomic, {bindings, _, _}}} =
               AL.run(
                 ~S"""
                 findall Value Values {
                   freeze Receiver {= Tag woke},
                   open_pick Receiver Value,
                   = Receiver #{class => open_child},
                   = Tag woke
                 }.
                 """,
                 branch,
                 trace: @trace
               )

      assert bindings["$Values"] == [[:child, :left]]
    end

    test "collection batches resume dispatch choices with #{inspect(trace)}", %{branch: branch} do
      assert %AL{result: {:atomic, {bindings, _, _}}} =
               AL.run(
                 "findall Batch Batches {findnsols 1 Value Batch {open_cut Receiver Value}}.",
                 branch,
                 trace: @trace
               )

      assert Enum.sort(bindings["$Batches"]) == [[:left], [:right]]
    end

    test "caller cut and commit prune dispatch alternatives with #{inspect(trace)}", %{
      branch: branch
    } do
      for body <- ["open_edit Receiver Owner _, cut", "open_edit Receiver Owner _ -> pass"] do
        assert %AL{result: {:atomic, {bindings, _, _}}} =
                 AL.run("findall Owner Owners {#{body}}.", branch, trace: @trace)

        assert [owner] = bindings["$Owners"]
        assert owner in [:open_left, :open_right]
      end
    end

    test "singleton providers and selector enumeration agree with #{inspect(trace)}", %{
      branch: branch
    } do
      assert %AL{result: {:atomic, {bindings, _, _}}} =
               AL.run(
                 ~S"""
                 findall Value Values {open_single Receiver Value, = Receiver open_singleton}.
                 findall Selector Selectors {
                   in_domain Selector [open_single, absent],
                   send open_singleton Selector [one]
                 }.
                 """,
                 branch,
                 trace: @trace
               )

      assert bindings["$Values"] == [:one, :two]
      assert bindings["$Selectors"] == [:open_single]
    end
  end

  test "open dispatch traces method exits and provider retries", %{branch: branch} do
    assert %AL{result: {:atomic, {bindings, _, first}}} =
             AL.run("open_edit Receiver Owner Value.", branch, trace: [:domino])

    events = AL.Trace.payloads(first.trace.events)

    assert {:method_call, scope, _, :open_edit, _, _} =
             Enum.find(events, &match?({:method_call, _, _, :open_edit, _, _}, &1))

    assert Enum.any?(events, &match?({:method_exit, ^scope, _}, &1))

    assert [{_, [owner, :old]}] =
             first |> AL.Trace.Derivation.build() |> AL.Trace.Derivation.method_values(:open_edit)

    assert owner == bindings["$Owner"]

    assert %AL{result: {:atomic, {_, _, second}}} = AL.next_solution(first)
    events = AL.Trace.payloads(second.trace.events)
    assert {:method_redo, scope} in events
    assert Enum.count(events, &match?({:method_exit, ^scope, _}, &1)) == 2
  end
end
