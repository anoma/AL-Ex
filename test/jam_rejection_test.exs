defmodule AL.JAM.RejectionTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)

    assert {:atomic, _} =
             AL.eval_source(
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
        AL.JAM.IR.Rejection.select(clauses, index.rejections, [receiver, input, :"$Kind"], store)
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

    assert {:atomic, _} = AL.eval_source(clauses, branch)

    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"""
               findall Output Atoms {many #{class => rejection_probe} example Output},
               findall Output Numbers {many #{class => rejection_probe} 42 Output}.
               """,
               branch
             )

    assert bindings[:"$Atoms"] == Enum.to_list(0..68//2) ++ [0]
    assert bindings[:"$Numbers"] == Enum.to_list(1..69//2)
  end

  test "one type decision rejects incompatible clauses before head matching", %{branch: branch} do
    assert length(candidates([1], branch)) == 1
    assert length(candidates("text", branch)) == 1
    assert length(candidates(%AL.Goal.Compound{name: :item, args: [1]}, branch)) == 1
    assert candidates(42, branch) == []
    assert candidates(%{class: :compound}, branch) == []
    assert length(candidates(:"$Input", branch)) == 5
    assert length(candidates(:"$Alias", branch, %{:"$Alias" => :"$Input", :"$Input" => [1]})) == 1

    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"""
               findall Kind Kinds {choose #{class => rejection_probe} [1] Kind}.
               """,
               branch
             )

    assert bindings[:"$Kinds"] == [:list]
  end

  test "open arguments retain constraint-producing alternatives in order", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"""
               findall Kind Kinds {choose #{class => rejection_probe} Input Kind, = Input []}.
               """,
               branch
             )

    assert bindings[:"$Kinds"] == [:list, :open]
  end

  test "durable classes and unknown map classes remain runtime relations", %{branch: branch} do
    assert length(candidates(:rejection_item, branch)) == 3
    assert length(candidates(%{class: :"$Class"}, branch)) == 2

    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"""
               vm_set_class rejection_item list,
               findall Kind Kinds {choose #{class => rejection_probe} rejection_item Kind},
               choose #{class => rejection_probe} #{class => Class} list.
               """,
               branch
             )

    assert bindings[:"$Kinds"] == [:atom, :list]
    assert bindings[:"$Class"] == :list
  end

  test "body failure remains failure when all rejection tests fail", %{branch: branch} do
    assert {:atomic, _} =
             AL.eval_source(
               ~S"""
               rejection_probe >> does_not_understand
               | _Self choose _Args |.
               """,
               branch
             )

    assert {:aborted, _} = AL.eval_source("choose \#{class => rejection_probe} 42 Kind.", branch)
    assert {:atomic, _} = AL.eval_source("choose \#{class => rejection_probe}.", branch)
  end

  test "rejected matching heads still fail when retained heads do not match", %{branch: branch} do
    assert {:atomic, _} =
             AL.eval_source(
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

    assert {:aborted, _} =
             AL.eval_source("guarded \#{class => rejection_probe} [] wanted.", branch)
  end

  test "effects and cuts before tests retain their execution boundaries", %{branch: branch} do
    assert {:atomic, _} =
             AL.eval_source(
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

    assert {:aborted, _} = AL.eval_source("committed \#{class => rejection_probe} [].", branch)
  end

  test "method replacement refreshes rejection decisions and keeps duplicate answers", %{
    branch: branch
  } do
    assert length(candidates([1], branch)) == 1

    assert {:atomic, _} =
             AL.eval_source(
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

    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"""
               findall Kind Kinds {choose #{class => rejection_probe} [] Kind}.
               """,
               branch
             )

    assert bindings[:"$Kinds"] == [:yes, :yes]
  end
end
