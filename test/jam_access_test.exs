defmodule AL.JAM.AccessTest do
  use ExUnit.Case, async: true
  alias AL.{Goal, Var}
  alias AL.JAM.{IR, Primitive, Unification}

  test "head unification retains nested aliases and checks later bindings" do
    branch = AL.Branch.head()
    initial = %{:"$Input" => [1, :"$Item" | :"$Tail"]}
    store = Unification.unify(:"$Output", :"$Input", initial, branch)
    store = Var.unify(:"$Item", 2, store, branch)
    store = Var.unify(:"$Tail", [3], store, branch)
    assert Var.subst(:"$Output", store) == [1, 2, 3]
    assert Unification.unify(:"$Output", [1, 2, 3], store, branch)
    assert Unification.unify(:"$Output", [1, 4, 3], store, branch) == nil
  end

  test "reference binding preserves occurs checks and disequality constraints" do
    branch = AL.Branch.head()
    assert Unification.unify(:"$X", [1 | :"$X"], %{}, branch) == nil
    store = Var.dif_value(:"$X", [1, 2], %{}, branch)
    assert Unification.unify(:"$X", [1, 2], store, branch) == nil
    assert Unification.unify(:"$X", [1, 3], store, branch)
  end

  test "aliased map keys are resolved when structures are compared" do
    branch = AL.Branch.head()
    store = %{:"$Key" => :name, :"$Value" => :answer}
    store = Unification.unify(:"$Map", %{:"$Key" => :"$Value"}, store, branch)
    assert Unification.unify(:"$Map", %{name: :answer}, store, branch)
    assert Unification.unify(:"$Map", %{name: :other}, store, branch) == nil
  end

  test "repeated head variables see bindings made earlier in the same match" do
    branch = AL.Branch.head()
    assert Unification.unify([:"$X", :"$X"], [1, 2], %{}, branch) == nil
    store = Unification.unify([:"$X", :"$X"], [1, 1], %{}, branch)
    assert Var.subst(:"$X", store) == 1
  end

  test "functor access retains open fields and resolves aliases in both directions" do
    branch = AL.Branch.head()
    term = %Goal.Compound{name: :item, args: [:"$Value"]}
    slots = {term, :"$Name", :"$Args"}
    operands = Enum.map(0..2, &{:register, &1})
    args = Primitive.arguments(:functor, operands, slots, %{})
    assert {:ok, store} = Primitive.execute(:functor, args, %{}, branch)
    store = Var.unify(:"$Value", :answer, store, branch)
    assert Var.subst(:"$Name", store) == :item
    assert Var.subst(:"$Args", store) == [:answer]

    initial = %{:"$Name" => :item, :"$Args" => [:"$Value"], :"$Value" => :answer}
    args = Primitive.arguments(:functor, operands, {:"$Term", :"$Name", :"$Args"}, initial)

    assert {:atomic, {:ok, store}} =
             :mnesia.transaction(fn -> Primitive.execute(:functor, args, initial, branch) end)

    assert Var.subst(:"$Term", store) == %Goal.Compound{name: :item, args: [:answer]}
  end

  test "disequality stops at a mismatch but retains deferred constraints" do
    branch = AL.Branch.head()
    assert Unification.different([1 | :"$Tail"], [2 | :"$Other"], %{}, branch) == %{}
    assert Unification.different([1, :"$X"], [1, :"$X"], %{}, branch) == nil
    store = Unification.different([1, :"$X"], [1, 2], %{}, branch)
    assert Var.unify(:"$X", 2, store, branch) == nil
    assert Var.unify(:"$X", 3, store, branch)
    initial = %{:"$Key" => :name, :"$Value" => :answer}

    assert Unification.different(%{:"$Key" => :"$Value"}, %{name: :answer}, initial, branch) ==
             nil

    assert Unification.different(%{:"$Key" => :"$Value"}, %{name: :other}, initial, branch) ==
             initial
  end

  test "IR distinguishes deep equality inspection from shallow term access" do
    operations = [
      {IR.operation(:direct, :eq, [:"$X", :"$Y"]), [:shallow, :shallow]},
      {IR.operation(:term, :functor, [:"$X", :"$Name", :"$Args"]),
       [:shallow, :shallow, :shallow]},
      {IR.operation(:primitive, :equal, [:"$X", :"$Y"]), [:deep, :deep]}
    ]

    for {operation, access} <- operations do
      assert IR.Inference.operation(operation, MapSet.new()).access == access
    end

    slots = {[1, :"$Value"], [1, 2]}
    args = Primitive.arguments(:equal, [{:register, 0}, {:register, 1}], slots, %{:"$Value" => 2})
    assert {:ok, _} = Primitive.execute(:equal, args, %{:"$Value" => 2}, AL.Branch.head())
  end
end
