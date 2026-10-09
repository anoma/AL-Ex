defmodule AL.JAM.OptimizationEquivalenceTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)

    assert {:atomic, _} =
             AL.run(
               ~S"""
               @optimization_probe #{super => value}.
               optimization_probe >> route
               | Self Input Kind |
               classify Self Input Kind.
               optimization_probe >> classify
               | _Self Input atom |
               atom Input.
               optimization_probe >> classify
               | _Self Input list |
               class Input list.
               optimization_probe >> classify
               | _Self Input open |
               var Input.
               optimization_probe >> first
               | Self Value |
               pick Self Value,
               cut.
               optimization_probe >> pick
               | _Self first |.
               optimization_probe >> pick
               | _Self second |.
               optimization_probe >> calculate
               | _Self Input Result |
               = Result (+ Input 3).
               optimization_probe >> build
               | Self X Y Result |
               put Self x X First,
               put First y Y Result.
               optimization_probe >> x_value
               | Self X |
               get Self x X.
               optimization_probe >> project
               | Self X Y Result |
               build Self X Y Point,
               x_value Point Result.
               """,
               branch
             )

    %{branch: branch}
  end

  defp answer(source, branch, opts) do
    case AL.run(source, branch, opts) do
      {:atomic, {bindings, constraints, _state}} -> {:ok, bindings, constraints}
      {:aborted, _reason} -> :failure
    end
  end

  test "ground and open calls retain ordered alternatives", %{branch: branch} do
    for {source, expected} <- [
          {"findall Kind Kinds {route \#{class => optimization_probe} [] Kind}.", [:list]},
          {"findall Kind Kinds {route \#{class => optimization_probe} Input Kind, = Input []}.",
           [:list, :open]}
        ] do
      result = answer(source, branch, [])
      assert {:ok, %{"$Kinds" => ^expected}, _} = result
      assert result == answer(source, branch, trace: [:goals])
    end
  end

  test "cuts and failed calls agree with ordinary traced execution", %{branch: branch} do
    source = "findall Value Values {first \#{class => optimization_probe} Value}."
    result = answer(source, branch, [])
    assert {:ok, %{"$Values" => [:first]}, _} = result
    assert result == answer(source, branch, trace: [:goals])

    source = "route \#{class => optimization_probe} 42 Kind."
    assert answer(source, branch, []) == :failure
    assert answer(source, branch, trace: [:goals]) == :failure
  end

  test "arithmetic agrees after late binding in either direction", %{branch: branch} do
    for {source, expected} <- [
          {"calculate \#{class => optimization_probe} Input Result, = Input 2.",
           %{"$Input" => 2, "$Result" => 5}},
          {"calculate \#{class => optimization_probe} Input 5.", %{"$Input" => 2}}
        ] do
      result = answer(source, branch, [])
      assert {:ok, ^expected, _} = result
      assert result == answer(source, branch, trace: [:goals])
    end
  end

  test "inlined value methods preserve reverse bindings and escaping maps", %{branch: branch} do
    for {source, expected} <- [
          {"project \#{class => optimization_probe} X 20 12.", %{"$X" => 12}},
          {"build \#{class => optimization_probe} X X Result, get Result y 9.",
           %{"$X" => 9, "$Result" => %{class: :optimization_probe, x: 9, y: 9}}}
        ] do
      result = answer(source, branch, [])
      assert {:ok, ^expected, _} = result
      assert result == answer(source, branch, trace: [:goals])
    end
  end
end
