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

  # One check per relation table (class/super/method/oapply) -- these are
  # smoke tests that the package installer actually ran, not behavioral
  # tests of any one mechanism, so they're collapsed into a single example
  # rather than one per table.
  example bootstrapped_facts_exist_in_every_relation_table() do
    {:atomic, class_results} =
      :mnesia.transaction(fn -> AL.Object.scan_class(:"$object", :"$class") end)

    assert Enum.any?(class_results, &match?({:class, :object, _seq, :class}, &1))
    assert Enum.any?(class_results, &match?({:class, :behaviour, _seq, :class}, &1))

    {:atomic, super_results} =
      :mnesia.transaction(fn -> AL.Object.scan_super(:"$object", :"$super") end)

    assert Enum.any?(super_results, &match?({:super, :class, _seq, :object}, &1))
    assert Enum.any?(super_results, &match?({:super, :behaviour, _seq, :object}, &1))

    {:atomic, method_results} =
      :mnesia.transaction(fn ->
        AL.Object.scan_method(:"$object", :"$method_name", :"$method_id")
      end)

    assert {:method, :object, :defmethod, :defmethod} in method_results
    assert {:method, :object, :meta, :metaclass} in method_results

    {:atomic, oapply_results} =
      :mnesia.transaction(fn ->
        AL.Object.scan_oapply(:"$object", :"$seq", :"$head", :"$body")
      end)

    assert Enum.any?(oapply_results, fn {:oapply, id, _seq, head, _body} ->
             id == :defmethod and match?([_self, _method_name, _head, _body], head)
           end)

    :ok
  end
end
