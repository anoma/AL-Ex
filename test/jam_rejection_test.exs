defmodule AL.JAM.RejectionTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               @rejection_probe #{super => value}.
               rejection_probe >> choose
               | _Self Input Kind |
               atom Input,
               = Kind atom.
               rejection_probe >> choose
               | _Self Input Kind |
               class Input list,
               = Kind list.
               rejection_probe >> choose
               | _Self Input Kind |
               class Input string,
               = Kind string.
               rejection_probe >> choose
               | _Self Input Kind |
               functor Input _Name _Args,
               = Kind compound.
               rejection_probe >> choose
               | _Self Input Kind |
               var Input,
               = Kind open.
               """,
               branch
             )

    %{branch: branch}
  end

  defp candidates(input, branch, store \\ %{}) do
    {:atomic, selected} =
      :mnesia.transaction(fn ->
        receiver = %{class: :rejection_probe}
        {:ok, _, id} = AL.Dispatch.target(receiver, :choose, branch)
        {clauses, index} = AL.JAM.Compiler.fetch_method(id, branch)

        AL.JAM.IR.Rejection.select(
          clauses,
          index.rejections,
          [receiver, input, {:"$var", "Kind"}],
          store
        )
      end)

    selected
  end

  test "selection masks preserve duplicate answers and positions beyond a machine word", %{
    branch: branch
  } do
    clauses =
      Enum.map_join(Enum.to_list(0..69) ++ [0], "\n", fn value ->
        test = if rem(value, 2) == 0, do: "atom Input", else: "class Input number"
        "rejection_probe >> many\n| _Self Input Output |\n#{test},\n= Output #{value}."
      end)

    assert %AL{result: {:atomic, _}} = AL.run(clauses, branch)

    assert %AL{result: {:atomic, {bindings, _, _}}} =
             AL.run(
               ~S"""
               findall Output Atoms {many #{class => rejection_probe} example Output},
               findall Output Numbers {many #{class => rejection_probe} 42 Output}.
               """,
               branch
             )

    assert bindings["$Atoms"] == Enum.to_list(0..68//2) ++ [0]
    assert bindings["$Numbers"] == Enum.to_list(1..69//2)
  end

  test "one type decision rejects incompatible clauses before head matching", %{branch: branch} do
    assert length(candidates([1], branch)) == 1
    assert length(candidates("text", branch)) == 1
    assert length(candidates(%AL.Goal.Compound{name: :item, args: [1]}, branch)) == 1
    assert candidates(42, branch) == []
    assert candidates(%{class: :compound}, branch) == []
    assert length(candidates({:"$var", "Input"}, branch)) == 5

    assert length(
             candidates({:"$var", "Alias"}, branch, %{
               {:"$var", "Alias"} => {:"$var", "Input"},
               {:"$var", "Input"} => [1]
             })
           ) == 1

    assert %AL{result: {:atomic, {bindings, _, _}}} =
             AL.run(
               ~S"""
               findall Kind Kinds {choose #{class => rejection_probe} [1] Kind}.
               """,
               branch
             )

    assert bindings["$Kinds"] == [:list]
  end

  test "binary prefixes retain ordered alternatives, open modes and tracing", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               rejection_probe >> prefix
               | _Self Input Rest one |
               vm_text_concat "λ" Rest Input.
               rejection_probe >> prefix
               | _Self Input Rest two |
               vm_text_code Input 128512 Rest.
               rejection_probe >> prefix
               | _Self Input Rest three |
               vm_text_concat "λ😀" Rest Input.
               rejection_probe >> prefix
               | _Self Input Rest one |
               vm_text_concat "λ" Rest Input.
               """,
               branch
             )

    for trace <- [[], [:vm], [:goals], [:domino]] do
      assert %AL{result: {:atomic, {bindings, _, _}}} =
               AL.run(
                 ~S"""
                 findall [Rest, Kind] Answers {prefix #{class => rejection_probe} "λ😀!" Rest Kind}.
                 findall [Input, Kind] Generated {prefix #{class => rejection_probe} Input "!" Kind}.
                 """,
                 branch,
                 trace: trace
               )

      assert bindings["$Answers"] == [["😀!", :one], ["!", :three], ["😀!", :one]]
      assert bindings["$Generated"] == [["λ!", :one], ["😀!", :two], ["λ😀!", :three], ["λ!", :one]]
    end

    assert {:atomic, [_one, _three, _duplicate]} =
             :mnesia.transaction(fn ->
               receiver = %{class: :rejection_probe}
               {:ok, _, id} = AL.Dispatch.target(receiver, :prefix, branch)
               {clauses, index} = AL.JAM.Compiler.fetch_method(id, branch)

               AL.JAM.IR.Rejection.select(
                 clauses,
                 index.rejections,
                 [receiver, "λ😀!", nil, nil],
                 %{}
               )
             end)
  end

  test "open arguments retain constraint-producing alternatives in order", %{branch: branch} do
    assert %AL{result: {:atomic, {bindings, _, _}}} =
             AL.run(
               ~S"""
               findall Kind Kinds {choose #{class => rejection_probe} Input Kind, = Input []}.
               """,
               branch
             )

    assert bindings["$Kinds"] == [:list, :open]
  end

  test "sequence prefix tests preserve binary, list, and open inputs", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               rejection_probe >> sequence
               | _Self Input Rest one |
               = Input ["λ" . Rest].
               rejection_probe >> sequence
               | _Self Input Rest two |
               = ["😀" . Rest] Input.
               rejection_probe >> sequence
               | _Self Input Rest three |
               = ["λ", "😀" . Rest] Input.
               """,
               branch
             )

    for trace <- [[], [:goals], [:vm]], input <- ["λ😀!", ["λ", "😀", "!"], ["λ" | "😀!"]] do
      assert %AL{result: {:atomic, {bindings, %{}, _}}} =
               AL.run(
                 ~S"""
                 findall Kind Answers {sequence #{class => rejection_probe} Input _ Kind},
                 findall [Text, Kind] Generated {sequence #{class => rejection_probe} Text "!" Kind}.
                 """,
                 branch,
                 bindings: %{"Input" => input},
                 trace: trace
               )

      assert bindings["$Answers"] == [:one, :three]
      assert bindings["$Generated"] == [["λ!", :one], ["😀!", :two], ["λ😀!", :three]]
    end

    assert {:atomic, [_one, _three]} =
             :mnesia.transaction(fn ->
               receiver = %{class: :rejection_probe}
               {:ok, _, id} = AL.Dispatch.target(receiver, :sequence, branch)
               {clauses, index} = AL.JAM.Compiler.fetch_method(id, branch)

               AL.JAM.IR.Rejection.select(
                 clauses,
                 index.rejections,
                 [receiver, "λ😀!", nil, nil],
                 %{}
               )
             end)
  end

  test "durable classes and unknown map classes remain runtime relations", %{branch: branch} do
    assert length(candidates(:rejection_item, branch)) == 3
    assert length(candidates(%{class: {:"$var", "Class"}}, branch)) == 2

    assert %AL{result: {:atomic, {bindings, _, _}}} =
             AL.run(
               ~S"""
               vm_set_class rejection_item list,
               findall Kind Kinds {choose #{class => rejection_probe} rejection_item Kind},
               choose #{class => rejection_probe} #{class => Class} list.
               """,
               branch
             )

    assert bindings["$Kinds"] == [:atom, :list]
    assert bindings["$Class"] == :list
  end

  test "leading mode guards inside callables reject impossible alternatives", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               rejection_probe >> mode
               | _Self Input Kind |
               call [Input] {not {var Input}} [Input],
               = Kind bound.
               rejection_probe >> mode
               | _Self Input Kind |
               call [Input] {var Input} [Input],
               = Kind open.
               rejection_probe >> mode
               | _Self Input Kind |
               not {var Input},
               = Kind bound.
               """,
               branch
             )

    assert {:atomic, [1]} =
             :mnesia.transaction(fn ->
               receiver = %{class: :rejection_probe}
               {:ok, _, id} = AL.Dispatch.target(receiver, :mode, branch)
               {clauses, index} = AL.JAM.Compiler.fetch_method(id, branch)

               AL.JAM.IR.Rejection.select(
                 clauses,
                 index.rejections,
                 [receiver, {:"$var", "Input"}, {:"$var", "Kind"}],
                 %{}
               )
               |> Enum.map(& &1.sequence)
             end)

    for trace <- [[], [:goals], [:vm], [:domino]] do
      assert %AL{result: {:atomic, {bindings, _, _}}} =
               AL.run(
                 ~S"""
                 findall Kind Open {mode #{class => rejection_probe} Input Kind},
                 findall Kind Bound {mode #{class => rejection_probe} "x" Kind}.
                 """,
                 branch,
                 trace: trace
               )

      assert bindings["$Open"] == [:open]
      assert bindings["$Bound"] == [:bound, :bound]
    end
  end

  test "head matching may bind an argument before a nonvar guard", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               rejection_probe >> alias_mode
               | _Self Input Input bound |
               not {var Input}.
               rejection_probe >> alias_mode
               | _Self _Input _Other fallback |.
               rejection_probe >> structured_mode
               | _Self Input [_] bound |
               not {var Input}.
               rejection_probe >> structured_mode
               | _Self _Input _Other fallback |.
               """,
               branch
             )

    assert %AL{result: {:atomic, {bindings, _, _}}} =
             AL.run(
               ~S"""
               findall Kind Aliased {alias_mode #{class => rejection_probe} Input 1 Kind},
               findall Kind Structured {structured_mode #{class => rejection_probe} Input Input Kind}.
               """,
               branch
             )

    assert bindings["$Aliased"] == [:bound, :fallback]
    assert bindings["$Structured"] == [:bound, :fallback]
  end

  test "body failure remains failure when all rejection tests fail", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               rejection_probe >> does_not_understand
               | _Self choose _Args |.
               """,
               branch
             )

    assert %AL{result: {:aborted, _}} =
             AL.run("choose \#{class => rejection_probe} 42 Kind.", branch)

    assert %AL{result: {:atomic, _}} =
             AL.run("choose \#{class => rejection_probe}.", branch)
  end

  test "rejected matching heads still fail when retained heads do not match", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               rejection_probe >> guarded
               | _Self Input wanted |
               atom Input.
               rejection_probe >> guarded
               | _Self _Input other |.
               rejection_probe >> does_not_understand
               | _Self guarded _Args |.
               """,
               branch
             )

    assert %AL{result: {:aborted, _}} =
             AL.run("guarded \#{class => rejection_probe} [] wanted.", branch)
  end

  test "effects and cuts before tests retain their execution boundaries", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               rejection_probe >> effect
               | _Self Input |
               vm_set_class rejection_effect list,
               atom Input.
               rejection_probe >> effect
               | _Self _Input |.
               rejection_probe >> committed
               | _Self Input |
               cut,
               atom Input.
               rejection_probe >> committed
               | _Self _Input |.
               effect #{class => rejection_probe} [],
               class rejection_effect list.
               """,
               branch
             )

    assert %AL{result: {:aborted, _}} =
             AL.run("committed \#{class => rejection_probe} [].", branch)
  end

  test "cut after a driver effect keeps older search alternatives", %{branch: branch} do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               rejection_probe >> cut_after_effect
               | _Self Choice |
               vm_set_class cut_boundary_effect list,
               member [a,b] Choice,
               cut.
               """,
               branch
             )

    query =
      "findall [Outer,Inner] Answers {member [1,2] Outer, cut_after_effect \#{class => rejection_probe} Inner}."

    for trace <- [[], [:vm]] do
      assert %AL{result: {:atomic, {%{"$Answers" => [[1, :a], [2, :a]]}, _, _}}} =
               AL.run(query, branch, trace: trace)
    end
  end

  test "a condition after a durable action resumes older alternatives", %{branch: branch} do
    query = ~S"""
    member [first, second] Choice,
    vm_set_class condition_boundary_effect list,
    vm_set_class condition_boundary_effect_two list,
    (= Choice second -> = Result committed ; = Result otherwise).
    """

    for trace <- [[], [:vm], [:domino], [:goals]] do
      assert %AL{result: {:atomic, {%{"$Choice" => :first, "$Result" => :otherwise}, _, first}}} =
               AL.run(query, branch, trace: trace)

      assert AL.has_potential_solution?(first)

      assert %AL{result: {:atomic, {%{"$Choice" => :second, "$Result" => :committed}, _, second}}} =
               AL.next_solution(first)

      assert %AL{result: {:aborted, _}} = AL.next_solution(second)
    end
  end

  test "failure after a durable action retries alternatives already in the machine", %{
    branch: branch
  } do
    query = ~S"""
    member [first, second] Choice,
    vm_set_class retry_action_effect list,
    = Choice second.
    """

    for trace <- [[], [:vm], [:domino]] do
      assert %AL{result: {:atomic, {%{"$Choice" => :second}, _, state}}} =
               AL.run(query, branch, trace: trace)

      assert %AL{result: {:aborted, _}} = AL.next_solution(state)
    end
  end

  test "a condition commits across an action boundary", %{branch: branch} do
    query = ~S"""
    {member [first, second] Choice,
     vm_set_class condition_commit_effect list,
     = Choice second} -> = Result committed ; = Result otherwise.
    """

    for trace <- [[], [:vm]] do
      assert %AL{result: {:atomic, {%{"$Choice" => :second, "$Result" => :committed}, _, state}}} =
               AL.run(query, branch, trace: trace)

      assert %AL{result: {:aborted, _}} = AL.next_solution(state)

      assert %AL{result: {:atomic, _}} =
               AL.run("class condition_commit_effect list.", branch)
    end
  end

  test "method replacement refreshes rejection decisions and keeps duplicate answers", %{
    branch: branch
  } do
    assert length(candidates([1], branch)) == 1

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               rejection_probe >> choose
               | _Self Input yes |
               class Input list.
               rejection_probe >> choose
               | _Self Input yes |
               class Input list.
               """,
               branch
             )

    assert length(candidates([1], branch)) == 2

    assert %AL{result: {:atomic, {bindings, _, _}}} =
             AL.run(
               ~S"""
               findall Kind Kinds {choose #{class => rejection_probe} [] Kind}.
               """,
               branch
             )

    assert bindings["$Kinds"] == [:yes, :yes]
  end
end
