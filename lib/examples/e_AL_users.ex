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
        new(:user, %{name: :alice}, alice)
        new(:user, %{name: :bob}, bob)
        new(:owned, %{owner: alice, label: :secret}, obj)
      end

    alice = Map.get(b, :"$alice")
    bob = Map.get(b, :"$bob")
    obj = Map.get(b, :"$obj")

    {:atomic, _} =
      run do
        oapply(:guarded_send, [^alice, ^obj, :update, [%{label: :updated}]])
      end

    {:atomic, {b2, _}} =
      run do
        get_slot(^obj, :label, l)
      end

    assert Map.get(b2, :"$l") == :updated

    {:aborted, _} =
      run do
        oapply(:guarded_send, [^bob, ^obj, :update, [%{label: :hacked}]])
      end

    :ok
  end

  example owned_class() do
    {:atomic, {b, _}} =
      run do
        new(:user, %{name: :alice}, alice)
        gensym(widget)
        new(:owned_class, %{name: widget, super: :owned, owner: alice}, _)
        new(widget, %{owner: alice, color: :red}, w)
        get_slot(widget, :owner, class_owner)
        get_slot(w, :owner, instance_owner)
        class(w, wc)
      end

    alice = Map.get(b, :"$alice")
    assert Map.get(b, :"$class_owner") == alice
    assert Map.get(b, :"$instance_owner") == alice
    assert Map.get(b, :"$wc") == Map.get(b, :"$widget")
    :ok
  end
end
