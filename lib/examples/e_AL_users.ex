defmodule Examples.ALUsers do
  @moduledoc """
  I provide user and ownership examples for AL
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example owner_is_a_slot() do
    {:atomic, {b, _}} =
      run do
        new(:user, %{name: :alice}, alice)
        new(:owned, %{owner: alice, label: :thing}, obj)
        get_slot(obj, :owner, owner)
        class(obj, c)
      end

    assert Map.get(b, :"$owner") == Map.get(b, :"$alice")
    assert Map.get(b, :"$c") == :owned
    :ok
  end

  example owner_gated_update() do    
    {:atomic, {b, _}} =
      run do
        new(:user, %{name: :bob}, bob)
        new(:user, %{name: :charlie}, charlie)
        new(:owned, %{owner: charlie, label: :secret}, obj)
      end

    charlie = Map.get(b, :"$charlie")
    bob = Map.get(b, :"$bob")
    obj = Map.get(b, :"$obj")

    {:atomic, _} =
      run do
        update(^obj, ^charlie, [%{label: :updated}])
      end

    {:atomic, {b2, _}} =
      run do
        get_slot(^obj, :label, l)
      end

    assert Map.get(b2, :"$l") == :updated

    {:aborted, _} =
      run do
        update(^obj, ^bob, [%{label: :hacked}])
      end
    
    :ok
  end
  end
