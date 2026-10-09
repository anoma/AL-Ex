defmodule AL.JAM.SearchTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)

    {:atomic, _} =
      AL.run(
        ~S"""
        list >> seek
        | [Value . _Tail] Value |.
        list >> seek
        | [_Head . Tail] Value |
        seek Tail Value.
        """,
        branch
      )

    %{branch: branch}
  end

  test "a structurally recognized search skips failed ground heads", %{branch: branch} do
    values = List.duplicate(:before, 1000) ++ [:found]
    goals = [%AL.Goal.Send{object: values, method: :seek, args: [:found]}]
    assert {:atomic, {_, _, state}} = AL.eval(goals, nil, branch)
    assert map_size(state.active_choicepoint.store) < 10
  end

  test "search keeps duplicates and open output enumeration in source order", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.run(
               ~S"""
               findall yes Matches {seek [before, found, after, found] found},
               findall Value Values {seek [first, second, first] Value}.
               """,
               branch
             )

    assert bindings["$Matches"] == [:yes, :yes]
    assert bindings["$Values"] == [:first, :second, :first]
  end

  test "unknown elements and structural values still unify", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.run(
               ~S"""
               seek [Value, after] found,
               seek [before, #{key => Nested}] #{key => 7},
               seek [before, 1, after] 1.0.
               """,
               branch
             )

    assert bindings["$Value"] == :found
    assert bindings["$Nested"] == 7
  end

  test "the last cell retains ordinary missing-method behavior", %{branch: branch} do
    {:atomic, _} =
      AL.run(
        ~S"""
        list >> does_not_understand
        | [] seek [missing] |.
        """,
        branch
      )

    assert {:atomic, _} = AL.run("seek [first, second, third] missing.", branch)
  end

  test "changing the recursive clause disables the cached search", %{branch: branch} do
    {:atomic, _} = AL.run("seek [first, second, third] third.", branch)

    {:atomic, _} =
      AL.run(
        ~S"""
        list >> seek
        | [Value . _Tail] Value |.
        list >> seek
        | [_Head . _Tail] changed |.
        """,
        branch
      )

    assert {:aborted, _} = AL.run("seek [first, second, third] third.", branch)
    assert {:atomic, _} = AL.run("seek [first, second, third] changed.", branch)
  end

  test "list-copy fusion preserves arbitrary elements and aliases", %{branch: branch} do
    {:atomic, _} =
      AL.run(
        ~S"""
        list >> join_parts
        | [] Tail Tail |.
        list >> join_parts
        | [Element . Elements] Tail [Element . Rest] |
        join_parts Elements Tail Rest.
        """,
        branch
      )

    assert {:atomic, {bindings, _, state}} =
             AL.run(
               ~S"""
               join_parts [Value, atom, #{key => Nested}] [end] Output,
               = Value 7,
               = Nested 8.
               """,
               branch
             )

    assert bindings["$Output"] == [7, :atom, %{key: 8}, :end]
    assert map_size(state.active_choicepoint.store) < 10
  end
end
