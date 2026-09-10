defmodule Examples.ALGtBridge do
  use ExExample
  use AL
  import ExUnit.Assertions

  example object_info_preserves_branch_and_slots() do
    branch = AL.Branch.fork()

    try do
      {:atomic, _} =
        AL.run branch: branch.id do
          vm_set_class(:inspector_sample, :object)
          set_slots(:inspector_sample, %{name: "Inspector sample", count: 3})
        end

      object = %AL.Object{id: :inspector_sample, branch: branch.id}
      assert AL.GtBridge.display_name(object) == "Inspector sample"
      rows = AL.GtBridge.object_info(object)

      assert {"Slots", "count", "3", 3} in rows
      assert {"Identity", "Branch", to_string(branch.id), branch} in rows
      assert Enum.all?(rows, fn {section, _, _, _} -> section in ["Identity", "Slots"] end)

      assert %AL.Object{id: :inspector_sample, branch: branch.id} in AL.GtBridge.instances(
               %AL.Object{id: :object, branch: branch.id}
             )

      :ok
    after
      AL.Branch.discard(branch)
    end
  end

  example inheritance_dag_contains_clickable_role_colored_objects() do
    branch = AL.Branch.fork()

    try do
      {:atomic, _} =
        AL.run branch: branch.id do
          vm_set_class(:inheritance_dag_instance, :inheritance_dag_class)
          vm_set_super(:inheritance_dag_class, :object)
          vm_set_super(:inheritance_dag_instance, :object)
        end

      graph =
        AL.GtBridge.inheritance_dag(%AL.Object{id: :inheritance_dag_instance, branch: branch.id})

      ids = Enum.map(graph.nodes, & &1.id)

      assert ids == [:inheritance_dag_instance, :inheritance_dag_class, :object]
      assert graph.roles[:inheritance_dag_instance] == :self
      assert graph.roles[:inheritance_dag_class] == :class
      assert graph.roles[:object] == :super
      assert graph.edges[:object] == [:inheritance_dag_class]
      assert graph.edges[:inheritance_dag_class] == [:inheritance_dag_instance]
      refute :inheritance_dag_instance in graph.edges[:object]
      assert Enum.all?(graph.nodes, fn node -> node.branch == branch.id end)
      :ok
    after
      AL.Branch.discard(branch)
    end
  end

  example inheritance_dag_handles_diamond_inheritance() do
    branch = AL.Branch.fork()

    try do
      {:atomic, _} =
        AL.run branch: branch.id do
          vm_set_super(:dag_base, :object)
          vm_set_super(:dag_left, :dag_base)
          vm_set_super(:dag_right, :dag_base)
          vm_set_super(:dag_child, :dag_left)
          vm_set_super(:dag_child, :dag_right)
          vm_set_class(:dag_instance, :dag_child)
        end

      graph = AL.GtBridge.inheritance_dag(%AL.Object{id: :dag_instance, branch: branch.id})

      assert MapSet.new(Enum.map(graph.nodes, & &1.id)) ==
               MapSet.new([:dag_instance, :dag_child, :dag_left, :dag_right, :dag_base, :object])

      assert graph.edges[:object] == [:dag_base]
      assert Enum.sort(graph.edges[:dag_base]) == [:dag_left, :dag_right]
      assert graph.edges[:dag_left] == [:dag_child]
      assert graph.edges[:dag_right] == [:dag_child]
      assert Enum.sort(graph.edges[:dag_child]) == [:dag_instance]
      assert graph.roles[:dag_instance] == :self
      assert graph.roles[:dag_child] == :class
      assert graph.roles[:dag_left] == :super
      assert graph.roles[:dag_right] == :super
      assert graph.roles[:dag_base] == :super
      assert graph.roles[:object] == :super
      :ok
    after
      AL.Branch.discard(branch)
    end
  end

  example program_execution_source_follows_inheritance() do
    branch = AL.Branch.fork()

    try do
      {:atomic, _} =
        AL.run branch: branch.id do
          vm_set_super(:inspector_execution_class, :program_execution)
          vm_set_class(:inspector_execution, :inspector_execution_class)
          get(:package_system, :tx, installed_tx)
          set_slots(:inspector_execution, %{name: :package_system, tx: installed_tx})
          vm_set_class(:inspector_unknown_execution, :program_execution)
          set_slots(:inspector_unknown_execution, %{name: :inspector_unknown_execution})
        end

      object = %AL.Object{id: :inspector_execution, branch: branch.id}
      assert {:ok, source} = AL.TransactionProgram.source(object)
      assert source =~ "defclass :channel"

      assert {:ok, ^source} =
               AL.TransactionProgram.source(%AL.Object{id: :package_system, branch: branch.id})

      assert :not_program_execution =
               AL.TransactionProgram.source(%AL.Object{id: :object, branch: branch.id})

      assert :not_program_execution =
               AL.TransactionProgram.source(%AL.Object{id: :program_execution, branch: branch.id})

      assert :not_program_execution =
               AL.TransactionProgram.source(%AL.Object{id: :inspector_execution, branch: :main})

      assert {:error, :source_unavailable} =
               AL.TransactionProgram.source(%AL.Object{
                 id: :inspector_unknown_execution,
                 branch: branch.id
               })

      :ok
    after
      AL.Branch.discard(branch)
    end
  end

  example failed_transactions_remain_inspectable() do
    branch = AL.Branch.fork_fresh()
    source = "fail()\n"

    try do
      assert {:aborted, failure} = AL.eval_source(source, branch)
      state = failure.state
      transaction = state.transaction_object
      tx = state.tx_id

      assert transaction == AL.Transaction.id(tx)

      {:atomic, {classes, slots}} =
        :mnesia.transaction(fn ->
          {
            AL.Object.scan_class(transaction, :transaction, branch),
            AL.Object.read_slots(transaction, branch)
          }
        end)

      assert [{:class, ^transaction, _seq, :transaction}] = classes
      assert [{:slots, ^transaction, %{status: :failed, reason: reason}}] = slots
      assert reason.message =~ "failed"

      {:atomic, {:source_text, ^tx, ^source, %{kind: :eval_source, label: nil}}} =
        :mnesia.transaction(fn -> AL.SourceStore.text(tx, branch) end)

      child = AL.Branch.fork(:tip, branch)

      try do
        assert {:atomic, [{:class, ^transaction, _seq, :transaction}]} =
                 :mnesia.transaction(fn -> AL.Object.scan_class(transaction, :_, child) end)

        assert {:atomic, {:source_text, ^tx, ^source, _}} =
                 :mnesia.transaction(fn -> AL.SourceStore.text(tx, child) end)
      after
        AL.Branch.discard(child)
      end

      :ok
    after
      AL.Branch.discard(branch)
    end
  end

  example program_execution_coders_show_installation_clauses() do
    branch = AL.Branch.fork()

    text = """
    vm_set_class(:program_execution_receiver_a, :object)
    vm_set_class(:program_execution_receiver_b, :object)
    defmethod(:program_execution_receiver_a, :hello, [self, result]) do
      unify(result, :original_a)
    end
    defmethod(:program_execution_receiver_b, :hello, [self, result]) do
      unify(result, :original_b)
    end
    new(:program_execution, %{name: :program_execution_coder_fixture, version: 1, deps: []}, _)
    """

    try do
      assert {:atomic, _} = AL.eval_source(text, branch)
      object = %AL.Object{id: :program_execution_coder_fixture, branch: branch.id}
      rows = AL.TransactionProgram.source_rows(object)
      assert length(rows) == 2
      assert length(Enum.uniq_by(rows, fn [name, seq | _] -> {name, seq} end)) == 2

      assert Enum.any?(rows, fn [_, _, source, _, _] -> source =~ "unify(result, :original_a)" end)

      assert Enum.any?(rows, fn [_, _, source, _, _] -> source =~ "unify(result, :original_b)" end)

      assert {:atomic, _} =
               AL.eval_source(
                 """
                 defmethod(:program_execution_receiver_a, :hello, [self, result]) do
                   unify(result, :later)
                 end
                 """,
                 branch
               )

      assert AL.TransactionProgram.source_rows(object) == rows
      assert AL.TransactionProgram.source_rows(%AL.Object{id: :object, branch: branch.id}) == []
      :ok
    after
      AL.Branch.discard(branch)
    end
  end

  example unnamed_object_uses_identity() do
    assert AL.GtBridge.display_name(%AL.Object{id: :object}) == "object"
    assert AL.GtBridge.display_name(%AL.Object{id: :inspector_missing}) == "inspector_missing"
    assert AL.GtBridge.object_title(%AL.Object{id: :blackjack}) == "AL.Object · :blackjack"
    :ok
  end

  example command_log_rows_are_readable() do
    [set_row, retract_row, send_row] =
      AL.Command.command_log_rows([
        {:command, 1, 10, {:set_class, {:child, :parent}}},
        {:command, 2, 10, {:retract_class, {:child, :parent}}},
        {:command, 3, 11, {:send_async, {:child, :ping, []}}}
      ])

    assert set_row.marker == "##"
    assert set_row.op == ":set_class"
    assert set_row.command == ":set_class -> {:child, :parent}"
    assert set_row.color == "#2563EB"
    assert set_row.action == "Class"
    assert set_row.target == ":child"
    assert set_row.details == ":child → :parent"
    assert retract_row.marker == "##"
    assert send_row.marker == "##"
    assert send_row.action == "Async Send"
    :ok
  end
end
