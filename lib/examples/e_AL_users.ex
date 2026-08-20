defmodule Examples.ALUsers do
  @moduledoc """
  I provide user and ownership examples for AL
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example owner_is_a_slot() do
    {:atomic, {b, _}} =
      run branch: :examples do
        new(:user, %{name: :alice}, alice)
        new(:owned, %{owner: alice, data: %{label: :thing}}, obj)
        get_slot(obj, :owner, owner)
        class(obj, c)
      end

    assert Map.get(b, :"$owner") == Map.get(b, :"$alice")
    assert Map.get(b, :"$c") == :owned
    :ok
  end

  example owner_gated_update() do
    {:atomic, {b, _}} =
      run branch: :examples do
        new(:user, %{name: :bob}, bob)
        new(:user, %{name: :charlie}, charlie)
        new(:owned, %{owner: charlie, data: %{label: :secret}}, obj)
      end

    charlie = Map.get(b, :"$charlie")
    bob = Map.get(b, :"$bob")
    obj = Map.get(b, :"$obj")

    {:atomic, _} =
      run branch: :examples do
        update(^obj, ^charlie, [%{data: %{label: :updated}}])
      end

    {:atomic, {b2, _}} =
      run branch: :examples do
        get_slot(^obj, :data, d)
      end

    assert Map.get(b2, :"$d") == %{label: :updated}

    {:aborted, _} =
      run branch: :examples do
        update(^obj, ^bob, [%{data: %{label: :hacked}}])
      end

    :ok
  end

  # An unspecified caller must be denied: the guard is structural equality, not
  # unification, so an unbound caller can't be silently bound to the owner.
  example owner_gate_rejects_unbound_caller() do
    {:atomic, {b, _}} =
      run branch: :examples do
        new(:user, %{name: :dana}, dana)
        new(:owned, %{owner: dana, data: %{label: :guarded}}, obj)
      end

    obj = Map.get(b, :"$obj")

    {:aborted, _} =
      run branch: :examples do
        update(^obj, caller, [%{data: %{label: :leaked}}])
      end

    {:atomic, {b2, _}} =
      run branch: :examples do
        get_slot(^obj, :data, d)
      end

    assert Map.get(b2, :"$d") == %{label: :guarded}
    :ok
  end
end
