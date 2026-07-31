defmodule Examples.ALBootstrap do
  @moduledoc """
  I provide bootstrap inspection examples for AL: `:main` is where bootstrap
  packages actually install (not `:examples`, which is itself forked from
  it), so these read `AL.Object` directly against the default branch rather
  than going through `run branch: :examples`.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example bootstrapped_classes() do
    {:atomic, class_results} =
      :mnesia.transaction(fn -> AL.Object.scan_class(:"$object", :"$class") end)

    assert Enum.any?(class_results, &match?({:class, :object, _seq, :class}, &1))
    assert Enum.any?(class_results, &match?({:class, :behaviour, _seq, :class}, &1))
    Enum.take(class_results, 3)
  end

  example bootstrapped_supers() do
    {:atomic, super_results} =
      :mnesia.transaction(fn -> AL.Object.scan_super(:"$object", :"$super") end)

    assert Enum.any?(super_results, &match?({:super, :class, _seq, :object}, &1))
    assert Enum.any?(super_results, &match?({:super, :behaviour, _seq, :object}, &1))
    Enum.take(super_results, 3)
  end

  example bootstrapped_methods() do
    {:atomic, method_results} =
      :mnesia.transaction(fn ->
        AL.Object.scan_method(:"$object", :"$method_name", :"$method_id")
      end)

    assert {:method, :object, :defmethod, :defmethod} in method_results
    assert {:method, :object, :meta, :metaclass} in method_results
    Enum.take(method_results, 1)
  end

  example bootstrapped_oapply() do
    {:atomic, oapply_results} =
      :mnesia.transaction(fn ->
        AL.Object.scan_oapply(:"$object", :"$seq", :"$head", :"$body")
      end)

    assert Enum.any?(oapply_results, fn {:oapply, id, _seq, head, _body} ->
             id == :defmethod and match?([_self, _method_name, _head, _body], head)
           end)

    Enum.take(oapply_results, 1)
  end
end
