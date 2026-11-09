defmodule AL.JAM.SuspensionTest do
  use ExUnit.Case, async: true
  alias AL.JAM.Suspension

  test "waking one dependency removes the other subscriptions for that execution" do
    a = AL.Var.var("A")
    b = AL.Var.var("B")
    pending = Suspension.park(%{}, [a, b], [:goal])
    assert {%{}, [:goal]} = Suspension.ready(pending, %{a => "a"})
    assert {%{}, [:goal]} = Suspension.ready(pending, %{a => "a", b => "b"})
  end

  test "aliasing dependencies does not duplicate wakeups or merge separate goals" do
    a = AL.Var.var("A")
    b = AL.Var.var("B")
    pending = %{} |> Suspension.park([a, b], [:goal]) |> Suspension.park([b], [:goal])
    {pending, []} = Suspension.ready(pending, %{a => b})
    assert {%{}, [:goal, :goal]} = Suspension.ready(pending, %{a => b, b => "b"})
  end
end
