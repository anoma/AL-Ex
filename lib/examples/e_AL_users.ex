defmodule Examples.ALUsers do
  @moduledoc """
  I provide user and ownership examples for AL
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example owner_is_a_slot() do
    {:atomic, {b, _constraints, _}} =
      run(
        ~S"""
        new user #{name => alice} Alice.
        new owned #{data => #{label => thing}, owner => Alice} Obj.
        get Obj owner Owner.
        class Obj C.
        """,
        branch: Examples.Support.branch()
      )

    assert Map.get(b, "$Owner") == Map.get(b, "$Alice")
    assert Map.get(b, "$C") == :owned
    :ok
  end

  example owned_subclasses_apply_their_declared_ivar_specs() do
    {:atomic, _} =
      run(
        ~S"""
        @owned_ivar_probe
        #{super => owned, ivars => [#{default => [], name => items, type => list}]}.
        """,
        branch: Examples.Support.branch()
      )

    {:atomic, {creation_bindings, _constraints, _}} =
      run(
        ~S"""
        new owned_ivar_probe #{} Object.
        """,
        branch: Examples.Support.branch()
      )

    object = Map.fetch!(creation_bindings, "$Object")

    {:atomic, {slot_bindings, _constraints, _}} =
      run(
        ~S"""
        findall [Key, Value] Slots (slot HostObject Key Value).
        """,
        branch: Examples.Support.branch(),
        bindings: %{"HostObject" => object}
      )

    assert Map.get(slot_bindings, "$Slots") == [[:items, []]]

    {:atomic, {get_bindings, _constraints, _}} =
      run(
        ~S"""
        get HostObject items Items.
        """,
        branch: Examples.Support.branch(),
        bindings: %{"HostObject" => object}
      )

    assert Map.get(get_bindings, "$Items") == []
    :ok
  end

  example owner_gated_update() do
    {:atomic, {b, _constraints, _}} =
      run(
        ~S"""
        new user #{name => bob} Bob.
        new user #{name => charlie} Charlie.
        new owned #{data => #{label => secret}, owner => Charlie} Obj.
        """,
        branch: Examples.Support.branch()
      )

    charlie = Map.get(b, "$Charlie")
    bob = Map.get(b, "$Bob")
    obj = Map.get(b, "$Obj")

    {:atomic, _} =
      run(
        ~S"""
        update HostObj HostCharlie [#{data => #{label => updated}}].
        """,
        branch: Examples.Support.branch(),
        bindings: %{"HostCharlie" => charlie, "HostObj" => obj}
      )

    {:atomic, {b2, _constraints, _}} =
      run(
        ~S"""
        get HostObj data D.
        """,
        branch: Examples.Support.branch(),
        bindings: %{"HostObj" => obj}
      )

    assert Map.get(b2, "$D") == %{label: :updated}

    {:aborted, _} =
      run(
        ~S"""
        update HostObj HostBob [#{data => #{label => hacked}}].
        """,
        branch: Examples.Support.branch(),
        bindings: %{"HostBob" => bob, "HostObj" => obj}
      )

    :ok
  end

  # An unspecified caller must be denied: ground is checked before the
  # relational slot lookup, so an unbound caller can't be bound to the owner.
  example owner_gate_rejects_unbound_caller() do
    {:atomic, {b, _constraints, _}} =
      run(
        ~S"""
        new user #{name => dana} Dana.
        new owned #{data => #{label => guarded}, owner => Dana} Obj.
        """,
        branch: Examples.Support.branch()
      )

    obj = Map.get(b, "$Obj")

    {:aborted, _} =
      run(
        ~S"""
        update HostObj Caller [#{data => #{label => leaked}}].
        """,
        branch: Examples.Support.branch(),
        bindings: %{"HostObj" => obj}
      )

    {:atomic, {b2, _constraints, _}} =
      run(
        ~S"""
        get HostObj data D.
        """,
        branch: Examples.Support.branch(),
        bindings: %{"HostObj" => obj}
      )

    assert Map.get(b2, "$D") == %{label: :guarded}
    :ok
  end
end
