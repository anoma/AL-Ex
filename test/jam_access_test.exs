defmodule AL.JAM.AccessTest do
  use ExUnit.Case, async: true
  alias AL.{Goal, Var}
  alias AL.JAM.{IR, Primitive, Unification}

  test "head unification retains nested aliases and checks later bindings" do
    branch = AL.Branch.head()
    initial = %{{:"$var", "Input"} => [1, {:"$var", "Item"} | {:"$var", "Tail"}]}
    store = Unification.unify({:"$var", "Output"}, {:"$var", "Input"}, initial, branch)
    store = Var.unify({:"$var", "Item"}, 2, store, branch)
    store = Var.unify({:"$var", "Tail"}, [3], store, branch)
    assert Var.subst({:"$var", "Output"}, store) == [1, 2, 3]
    assert Unification.unify({:"$var", "Output"}, [1, 2, 3], store, branch)
    assert Unification.unify({:"$var", "Output"}, [1, 4, 3], store, branch) == nil
  end

  test "reference binding preserves occurs checks and disequality constraints" do
    branch = AL.Branch.head()
    assert Unification.unify({:"$var", "X"}, [1 | {:"$var", "X"}], %{}, branch) == nil
    store = Var.dif_value({:"$var", "X"}, [1, 2], %{}, branch)
    assert Unification.unify({:"$var", "X"}, [1, 2], store, branch) == nil
    assert Unification.unify({:"$var", "X"}, [1, 3], store, branch)
  end

  test "aliased map keys are resolved when structures are compared" do
    branch = AL.Branch.head()
    store = %{{:"$var", "Key"} => :name, {:"$var", "Value"} => :answer}

    store =
      Unification.unify(
        {:"$var", "Map"},
        %{{:"$var", "Key"} => {:"$var", "Value"}},
        store,
        branch
      )

    assert Unification.unify({:"$var", "Map"}, %{name: :answer}, store, branch)
    assert Unification.unify({:"$var", "Map"}, %{name: :other}, store, branch) == nil
  end

  test "repeated head variables see bindings made earlier in the same match" do
    branch = AL.Branch.head()
    assert Unification.unify([{:"$var", "X"}, {:"$var", "X"}], [1, 2], %{}, branch) == nil
    store = Unification.unify([{:"$var", "X"}, {:"$var", "X"}], [1, 1], %{}, branch)
    assert Var.subst({:"$var", "X"}, store) == 1
  end

  test "functor access retains open fields and resolves aliases in both directions" do
    branch = AL.Branch.head()
    term = %Goal.Compound{name: :item, args: [{:"$var", "Value"}]}
    slots = {term, {:"$var", "Name"}, {:"$var", "Args"}}
    operands = Enum.map(0..2, &{:register, &1})
    args = Primitive.arguments(:functor, operands, slots, %{})
    assert {:ok, store} = Primitive.execute(:functor, args, %{}, branch)
    store = Var.unify({:"$var", "Value"}, :answer, store, branch)
    assert Var.subst({:"$var", "Name"}, store) == :item
    assert Var.subst({:"$var", "Args"}, store) == [:answer]

    initial = %{
      {:"$var", "Name"} => :item,
      {:"$var", "Args"} => [{:"$var", "Value"}],
      {:"$var", "Value"} => :answer
    }

    args =
      Primitive.arguments(
        :functor,
        operands,
        {{:"$var", "Term"}, {:"$var", "Name"}, {:"$var", "Args"}},
        initial
      )

    assert {:atomic, {:ok, store}} =
             :mnesia.transaction(fn -> Primitive.execute(:functor, args, initial, branch) end)

    assert Var.subst({:"$var", "Term"}, store) == %Goal.Compound{name: :item, args: [:answer]}
  end

  test "disequality stops at a mismatch but retains deferred constraints" do
    branch = AL.Branch.head()

    assert Unification.different([1 | {:"$var", "Tail"}], [2 | {:"$var", "Other"}], %{}, branch) ==
             %{}

    assert Unification.different([1, {:"$var", "X"}], [1, {:"$var", "X"}], %{}, branch) == nil
    store = Unification.different([1, {:"$var", "X"}], [1, 2], %{}, branch)
    assert Var.unify({:"$var", "X"}, 2, store, branch) == nil
    assert Var.unify({:"$var", "X"}, 3, store, branch)
    initial = %{{:"$var", "Key"} => :name, {:"$var", "Value"} => :answer}

    assert Unification.different(
             %{{:"$var", "Key"} => {:"$var", "Value"}},
             %{name: :answer},
             initial,
             branch
           ) ==
             nil

    assert Unification.different(
             %{{:"$var", "Key"} => {:"$var", "Value"}},
             %{name: :other},
             initial,
             branch
           ) ==
             initial
  end

  test "IR distinguishes deep equality inspection from shallow term access" do
    operations = [
      {IR.operation(:direct, :eq, [{:"$var", "X"}, {:"$var", "Y"}]), [:shallow, :shallow]},
      {IR.operation(:term, :functor, [{:"$var", "X"}, {:"$var", "Name"}, {:"$var", "Args"}]),
       [:shallow, :shallow, :shallow]},
      {IR.operation(:primitive, :equal, [{:"$var", "X"}, {:"$var", "Y"}]), [:deep, :deep]}
    ]

    for {operation, access} <- operations do
      assert IR.Inference.operation(operation, MapSet.new()).access == access
    end

    slots = {[1, {:"$var", "Value"}], [1, 2]}

    args =
      Primitive.arguments(:equal, [{:register, 0}, {:register, 1}], slots, %{
        {:"$var", "Value"} => 2
      })

    assert {:ok, _} =
             Primitive.execute(:equal, args, %{{:"$var", "Value"} => 2}, AL.Branch.head())
  end
end
