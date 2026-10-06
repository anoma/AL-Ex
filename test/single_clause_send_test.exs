defmodule AL.SingleClauseSendTest do
  use ExUnit.Case, async: false

  test "a clause added after a send is visible in the same transaction" do
    {:atomic, _result} =
      AL.eval_source(~S"""
      @send_plan_probe #{super => object}.

      send_plan_probe >> pick
      | _Self old |.

      vm_set_class send_plan_instance send_plan_probe.
      pick send_plan_instance old.
      defmethod send_plan_probe pick [_Self, new] {}.
      pick send_plan_instance new.
      """)
  end

  test "a single clause keeps body alternatives and next-method dispatch" do
    {:atomic, {bindings, _constraints, _state}} =
      AL.eval_source(~S"""
      @send_plan_parent #{super => object}.

      send_plan_parent >> describe
      | _Self parent |.

      @send_plan_child #{super => send_plan_parent}.

      send_plan_child >> describe
      | Self [child, Parent] |
      call_next_method Self Parent.

      send_plan_child >> choose
      | _Self X |
      member [red, blue] X.

      vm_set_class send_plan_child_instance send_plan_child.
      describe send_plan_child_instance Description.
      findall X Choices {choose send_plan_child_instance X}.
      """)

    assert bindings[:"$Description"] == [:child, :parent]
    assert bindings[:"$Choices"] == [:red, :blue]
  end

  test "open arguments retain multiple matching clauses in source order" do
    {:atomic, {bindings, _constraints, _state}} =
      AL.eval_source(~S"""
      @send_mode_probe #{super => object}.

      send_mode_probe >> choose
      | _Self red red |.

      send_mode_probe >> choose
      | _Self blue blue |.

      vm_set_class send_mode_instance send_mode_probe.
      findall Color Colors {choose send_mode_instance Color Color}.
      choose send_mode_instance blue blue.
      """)

    assert bindings[:"$Colors"] == [:red, :blue]
  end

  test "next-method dispatch works inside a nested goal" do
    {:atomic, {bindings, _constraints, _state}} =
      AL.eval_source(~S"""
      @nested_next_parent #{super => object}.

      nested_next_parent >> describe
      | _Self parent |.

      @nested_next_child #{super => nested_next_parent}.

      nested_next_child >> describe
      | Self [child, Parent] |
      {call_next_method Self Parent} ; {= Parent fallback}.

      vm_set_class nested_next_instance nested_next_child.
      describe nested_next_instance Description.
      """)

    assert bindings[:"$Description"] == [:child, :parent]
  end
end
