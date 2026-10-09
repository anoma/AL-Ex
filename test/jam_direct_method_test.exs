defmodule AL.JAM.DirectMethodTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)

    assert {:atomic, _} =
             AL.run(
               ~S"""
               @direct_method_probe #{super => value}.
               direct_method_probe >> pick
               | _Self first |.
               direct_method_probe >> pick
               | _Self second |.
               """,
               branch
             )

    %{branch: branch}
  end

  test "direct calls accept unrelated receivers and preserve ordered alternatives", %{
    branch: branch
  } do
    assert {:atomic, {bindings, _, _}} =
             AL.run(
               ~S"""
               method direct_method_probe pick Id,
               findall Value Values {vm_oapply Id [unrelated, Value]},
               vm_oapply Id [#{class => list}, second].
               """,
               branch
             )

    assert bindings["$Values"] == [:first, :second]
  end

  test "open argument lists and aliased structured heads keep relational modes", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.run(
               ~S"""
               direct_method_probe >> relate
               | _Self [Value . Tail] #{value => Value} Tail |.
               method direct_method_probe relate Id,
               = Args [unrelated, Input, #{value => 7}, []],
               vm_oapply Id Args,
               vm_oapply Id [unrelated, [X], #{value => Y}, []],
               = X 8.
               """,
               branch
             )

    assert bindings["$Input"] == [7]
    assert bindings["$Y"] == 8
  end

  test "direct target caches refresh after method edits in the same transaction", %{
    branch: branch
  } do
    assert {:atomic, {bindings, _, _}} =
             AL.run(
               ~S"""
               method direct_method_probe pick Id,
               findall Value Before {vm_oapply Id [unrelated, Value]},
               defmethod direct_method_probe pick [_Self, third] {},
               findall Value After {vm_oapply Id [unrelated, Value]}.
               """,
               branch
             )

    assert bindings["$Before"] == [:first, :second]
    assert bindings["$After"] == [:first, :second, :third]
  end

  test "direct calls preserve method cut scopes", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.run(
               ~S"""
               direct_method_probe >> limited
               | _Self Value |
               member [first, second] Value,
               cut.
               direct_method_probe >> limited
               | _Self third |.
               method direct_method_probe limited Id,
               findall [Input, Value] Values {member [a, b] Input, vm_oapply Id [Input, Value]}.
               """,
               branch
             )

    assert bindings["$Values"] == [[:a, :first], [:b, :first]]
  end

  test "method identity reuse keeps public arguments and a different supplied target", %{
    branch: branch
  } do
    assert {:atomic, {bindings, _, _}} =
             AL.run(
               ~S"""
               direct_method_probe >> walk
               | _Self 0 _Id done |.
               direct_method_probe >> walk
               | Self N Id Result |
               > N 0,
               = Next (- N 1),
               vm_oapply Id [Self, Next, Id, Result].
               direct_method_probe >> other
               | _Self _N Id Result |
               = Result Id.
               method direct_method_probe walk Walk,
               method direct_method_probe other Other,
               vm_oapply Walk [unrelated, 3, Walk, Done],
               vm_oapply Walk [unrelated, 1, Other, Different],
               vm_oapply Walk [unrelated, 0, Open, Base],
               var Open.
               """,
               branch
             )

    assert bindings["$Done"] == :done
    assert bindings["$Base"] == :done
    assert bindings["$Different"] == bindings["$Other"]

    method = bindings["$Walk"]

    assert {:atomic, true} =
             :mnesia.transaction(fn ->
               {original, %{method_identity: {2, {specialized, _}}}} =
                 AL.JAM.Compiler.fetch_method(method, branch)

               assert Enum.all?(original ++ specialized, fn %AL.JAM.CompiledClause{head: head} ->
                        length(head) == 4
                      end)

               Enum.any?(specialized, fn %AL.JAM.CompiledClause{code: code} ->
                 Enum.any?(Tuple.to_list(code), fn
                   {:call_method, {:method_identity, ^method, 2}, _args} -> true
                   _ -> false
                 end)
               end)
             end)
  end

  test "a compiled recursive call sees edited method clauses", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.run(
               ~S"""
               direct_method_probe >> replace_self
               | Self N Id Result |
               clear_method direct_method_probe replace_self,
               defmethod direct_method_probe replace_self [_Receiver, Value, Target, Output] {
               = Output [Value, Target]
               },
               vm_oapply Id [Self, N, Id, Result].
               method direct_method_probe replace_self Id,
               vm_oapply Id [unrelated, 7, Id, Result].
               """,
               branch
             )

    assert bindings["$Result"] == [7, bindings["$Id"]]
  end

  test "reused identity preserves alternatives and observable argument uses", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.run(
               ~S"""
               direct_method_probe >> walk
               | _Self 0 Id Result |
               = Result [Id, first].
               direct_method_probe >> walk
               | _Self 0 Id Result |
               = Result [Id, second].
               direct_method_probe >> walk
               | Self N Id Result |
               > N 0,
               = Next (- N 1),
               vm_oapply Id [Self, Next, Id, Result].
               method direct_method_probe walk Id,
               findall Result Results {vm_oapply Id [unrelated, 2, Id, Result]}.
               """,
               branch
             )

    id = bindings["$Id"]
    assert bindings["$Results"] == [[id, :first], [id, :second]]

    assert {:atomic, true} =
             :mnesia.transaction(fn ->
               {_, index} = AL.JAM.Compiler.fetch_method(id, branch)
               index != nil and Map.has_key?(index, :method_identity)
             end)
  end
end
