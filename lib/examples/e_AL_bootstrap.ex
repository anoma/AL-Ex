defmodule Examples.ALBootstrap do
  @moduledoc """
  I provide bootstrap inspection examples for AL: `:main` is where bootstrap
  programs actually install (not `:examples`, which is itself forked from
  it), so these read `AL.Object` directly against the default branch rather
  than going through `run branch: Examples.Support.branch()`.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  # One check per relation table (class/super/method/oapply) -- these are
  # smoke tests that the program installer actually ran, not behavioral
  # tests of any one mechanism, so they're collapsed into a single example
  # rather than one per table.
  example bootstrapped_facts_exist_in_every_relation_table() do
    {:atomic, class_results} =
      :mnesia.transaction(fn -> AL.Object.scan_class({:"$var", "object"}, {:"$var", "class"}) end)

    assert Enum.any?(class_results, &match?({:class, :object, _seq, :class}, &1))
    assert Enum.any?(class_results, &match?({:class, :behaviour, _seq, :class}, &1))

    {:atomic, super_results} =
      :mnesia.transaction(fn -> AL.Object.scan_super({:"$var", "object"}, {:"$var", "super"}) end)

    assert Enum.any?(super_results, &match?({:super, :class, _seq, :object}, &1))
    assert Enum.any?(super_results, &match?({:super, :behaviour, _seq, :object}, &1))

    {:atomic, method_results} =
      :mnesia.transaction(fn ->
        AL.Object.scan_method(
          {:"$var", "object"},
          {:"$var", "method_name"},
          {:"$var", "method_id"}
        )
      end)

    assert {:method, :object, :defmethod, :defmethod} in method_results
    assert {:method, :object, :meta, :metaclass} in method_results

    {:atomic, oapply_results} =
      :mnesia.transaction(fn ->
        AL.Object.scan_oapply(
          {:"$var", "object"},
          {:"$var", "seq"},
          {:"$var", "head"},
          {:"$var", "body"}
        )
      end)

    assert Enum.any?(oapply_results, fn {:oapply, id, _seq, head, _body} ->
             id == :defmethod and match?([_self, _method_name, _head, _body], head)
           end)

    :ok
  end

  example projection_reads_preserve_query_variables_versions_and_branches() do
    branch = AL.Branch.fork()

    try do
      {:atomic, _} =
        AL.eval_source(
          ~S"""
          @projection_read_probe #{super => object}.
          projection_read_probe >> value
          | _Self red |.
          projection_read_probe >> value
          | _Self blue |.
          vm_set_method projection_read_probe same same.
          """,
          branch
        )

      {:atomic, id} =
        :mnesia.transaction(fn ->
          [{:method, :projection_read_probe, :value, id}] =
            AL.Object.scan_method(:projection_read_probe, :value, {:"$var", "Id"}, branch)

          methods =
            AL.Object.scan_method({:"$var", "Owner"}, {:"$var", "Name"}, {:"$var", "Id"}, branch)

          assert {:method, :projection_read_probe, :value, id} in methods

          assert AL.Object.scan_method(
                   :projection_read_probe,
                   {:"$var", "Same"},
                   {:"$var", "Same"},
                   branch
                 ) ==
                   [{:method, :projection_read_probe, :same, :same}]

          assert AL.Object.scan_method(
                   :projection_read_probe,
                   {:"$var", "tx_from"},
                   {:"$var", "seq"},
                   branch
                 ) ==
                   Enum.filter(methods, &(elem(&1, 1) == :projection_read_probe))

          clauses =
            AL.Object.scan_oapply(
              id,
              {:"$var", "Seq"},
              {:"$var", "Head"},
              {:"$var", "Body"},
              branch
            )

          assert length(clauses) == 2

          assert clauses ==
                   AL.Object.scan_oapply(
                     id,
                     {:"$var", "_"},
                     {:"$var", "_"},
                     {:"$var", "_"},
                     branch
                   )

          assert AL.Object.scan_oapply(
                   id,
                   {:"$var", "Seq"},
                   {:"$var", "Same"},
                   {:"$var", "Same"},
                   branch
                 ) == []

          assert AL.Object.scan_method(:projection_read_probe, :value, {:"$var", "Id"}) == []
          id
        end)

      {:atomic, _} =
        AL.eval_source(
          ~S"""
          projection_read_probe >> value
          | _Self green |.
          """,
          branch
        )

      {:atomic, _} =
        :mnesia.transaction(fn ->
          [{:method, :projection_read_probe, :value, ^id}] =
            AL.Object.scan_method(:projection_read_probe, :value, {:"$var", "Id"}, branch)

          [{:oapply, ^id, _, [_self, :green], []}] =
            AL.Object.scan_oapply(
              id,
              {:"$var", "Seq"},
              {:"$var", "Head"},
              {:"$var", "Body"},
              branch
            )

          assert length(
                   AL.Object.scan_oapply_history(
                     id,
                     {:"$var", "Seq"},
                     {:"$var", "Head"},
                     {:"$var", "Body"},
                     branch
                   )
                 ) ==
                   3
        end)
    after
      AL.Branch.discard(branch)
    end
  end
end
