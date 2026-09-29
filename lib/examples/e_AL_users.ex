defmodule Examples.ALUsers do
  @moduledoc """
  I provide user and ownership examples for AL
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example owner_is_a_slot() do
    {:atomic, {b, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new user #{name: alice} Alice.
        new owned #{data: #{label: thing}, owner: Alice} Obj.
        get Obj owner Owner.
        class Obj C.
        """
      end

    assert Map.get(b, :"$Owner") == Map.get(b, :"$Alice")
    assert Map.get(b, :"$C") == :owned
    :ok
  end

  example owned_subclasses_apply_their_declared_ivar_specs() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @owned_ivar_probe
        #{super: owned, ivars: [#{default: [], name: items, type: list}]}.
        """
      end

    {:atomic, {creation_bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new owned_ivar_probe #{} Object.
        """
      end

    object = Map.fetch!(creation_bindings, :"$Object")

    {:atomic, {slot_bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall [Key, Value] Slots {slot ^object Key Value}.
        """
      end

    assert Map.get(slot_bindings, :"$Slots") == [[:items, []]]

    {:atomic, {get_bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        get ^object items Items.
        """
      end

    assert Map.get(get_bindings, :"$Items") == []
    :ok
  end

  example owner_gated_update() do
    {:atomic, {b, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new user #{name: bob} Bob.
        new user #{name: charlie} Charlie.
        new owned #{data: #{label: secret}, owner: Charlie} Obj.
        """
      end

    charlie = Map.get(b, :"$Charlie")
    bob = Map.get(b, :"$Bob")
    obj = Map.get(b, :"$Obj")

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        update ^obj ^charlie [#{data: #{label: updated}}].
        """
      end

    {:atomic, {b2, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        get ^obj data D.
        """
      end

    assert Map.get(b2, :"$D") == %{label: :updated}

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        update ^obj ^bob [#{data: #{label: hacked}}].
        """
      end

    :ok
  end

  # An unspecified caller must be denied: ground is checked before the
  # relational slot lookup, so an unbound caller can't be bound to the owner.
  example owner_gate_rejects_unbound_caller() do
    {:atomic, {b, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new user #{name: dana} Dana.
        new owned #{data: #{label: guarded}, owner: Dana} Obj.
        """
      end

    obj = Map.get(b, :"$Obj")

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        update ^obj Caller [#{data: #{label: leaked}}].
        """
      end

    {:atomic, {b2, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        get ^obj data D.
        """
      end

    assert Map.get(b2, :"$D") == %{label: :guarded}
    :ok
  end
end
