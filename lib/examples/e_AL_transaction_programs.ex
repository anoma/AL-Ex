defmodule Examples.ALTransactionPrograms do
  @moduledoc """
  I provide examples for `AL.TransactionProgram`: transaction program install/uninstall.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example transaction_program_records_execution_and_effects() do
    branch = AL.Branch.fork()
    previous = AL.Branch.head()
    AL.Branch.checkout(branch)

    try do
      Code.compile_string("""
      defmodule Examples.TransactionProgramFixture do
        use AL.TransactionProgram

        defprogram :transaction_program_fixture, version: 2, deps: [:bootstrap] do
          vm_set_class(:program_created_object, :object)
          set_slot(:program_created_object, :answer, 42)
        end
      end
      """)

      assert %{name: :transaction_program_fixture, version: 2, deps: [:bootstrap]} =
               apply(Examples.TransactionProgramFixture, :__program__, [])

      assert {:atomic, _} = apply(Examples.TransactionProgramFixture, :install, [])

      result =
        AL.run do
          class(:transaction_program_fixture, :program_execution)
          get(:program_created_object, :answer, answer)
          get(:transaction_program_fixture, :tx, transaction)
          class(transaction, :transaction)
          listing(:transaction_program_fixture, source)
        end

      assert {:atomic, {bindings, _}} = result

      assert bindings[:"$answer"] == 42
      assert bindings[:"$source"] =~ "set_slot(:program_created_object, :answer, 42)"
      assert AL.TransactionProgram.installed?(:transaction_program_fixture)

      assert :ok =
               AL.TransactionProgram.ensure(:transaction_program_fixture, fn ->
                 flunk("ran twice")
               end)

      assert {:atomic, _} = AL.TransactionProgram.uninstall(:transaction_program_fixture)
      refute AL.TransactionProgram.installed?(:transaction_program_fixture)
      :ok
    after
      AL.Branch.checkout(previous)
      AL.Branch.discard(branch)
      :code.purge(Examples.TransactionProgramFixture)
      :code.delete(Examples.TransactionProgramFixture)
    end
  end

  example startup_uses_transaction_program_configuration() do
    old_programs = Application.fetch_env(:al, :transaction_programs)
    old_packages = Application.fetch_env(:al, :packages)

    try do
      Application.put_env(:al, :transaction_programs, [AL.TransactionProgram.Bootstrap])
      Application.put_env(:al, :packages, [:unrelated_package_configuration])
      assert AL.TransactionProgram.configured() == [AL.TransactionProgram.Bootstrap]
      :ok
    after
      restore_configuration(:transaction_programs, old_programs)
      restore_configuration(:packages, old_packages)
    end
  end

  example legacy_receipts_survive_execution_protocol_setup() do
    branch = AL.Branch.fork(0, AL.Branch.main())
    previous = AL.Branch.head()
    AL.Branch.checkout(branch)

    try do
      assert {:atomic, _} = AL.TransactionProgram.Bootstrap.install()

      scaffold = """
      new(:class, %{name: :package, super: :object, ivars: [:name, :version, :deps, :tx]}, _)
      import(:package, :program_execution)
      vm_retract_class(:bootstrap, :program_execution)
      vm_set_class(:bootstrap, :package)
      delete_class(:program_execution)
      """

      assert {:atomic, _} = AL.eval_source(scaffold, branch)

      source = """
      vm_set_class(:legacy_receipt_effect, :object)
      new(:package, %{name: :legacy_receipt, version: 1, deps: []}, _)
      """

      assert {:atomic, _} = AL.eval_source(source, branch)
      object = %AL.Object{id: :legacy_receipt, branch: branch.id}
      assert AL.TransactionProgram.installed?(:legacy_receipt)
      assert {:ok, ^source} = AL.TransactionProgram.source(object)

      programs = [
        AL.TransactionProgram.Bootstrap,
        AL.TransactionProgram.PackageSystem
      ]

      assert :ok = AL.TransactionProgram.install_all(programs)
      assert :ok = AL.TransactionProgram.install_all(programs)
      assert {:ok, ^source} = AL.TransactionProgram.source(object)

      assert {:atomic, [{:class, :legacy_receipt, _seq, :program_execution}]} =
               :mnesia.transaction(fn ->
                 AL.Object.scan_class(:legacy_receipt, :program_execution, branch)
               end)

      assert {:atomic, []} =
               :mnesia.transaction(fn ->
                 AL.Object.scan_class(AL.Var.var("legacy_receipt"), :package, branch)
               end)

      assert {:atomic, [{:class, :package, _seq, :class}]} =
               :mnesia.transaction(fn -> AL.Object.scan_class(:package, :class, branch) end)

      assert {:atomic, [{:super, :package, _seq, :class}]} =
               :mnesia.transaction(fn -> AL.Object.scan_super(:package, :class, branch) end)

      result =
        AL.run do
          new(:program_execution, %{name: :new_receipt, version: 1, deps: [:legacy_receipt]}, _)
          listing(:legacy_receipt, source)
        end

      assert {:atomic, {bindings, _}} = result
      assert bindings[:"$source"] == source

      assert {:error, {:depended_on_by, [:new_receipt]}} =
               AL.TransactionProgram.uninstall(:legacy_receipt)

      child = AL.Branch.fork(:tip, branch)

      try do
        assert {:ok, ^source} =
                 AL.TransactionProgram.source(%AL.Object{id: :legacy_receipt, branch: child.id})
      after
        AL.Branch.discard(child)
      end

      assert {:atomic, _} = AL.TransactionProgram.uninstall(:new_receipt)
      assert {:atomic, _} = AL.TransactionProgram.uninstall(:legacy_receipt)
      refute AL.TransactionProgram.installed?(:legacy_receipt)
      :ok
    after
      AL.Branch.checkout(previous)
      AL.Branch.discard(branch)
    end
  end

  example listing_uses_installed_source_after_recompile() do
    branch = AL.Branch.fork()
    previous = AL.Branch.head()
    AL.Branch.checkout(branch)

    source = """
    defmodule Examples.RetainedProgramFixture do
      use AL.TransactionProgram
      defprogram :retained_program_fixture, version: 1, deps: [] do
        vm_set_class(:retained_original, :object)
      end
    end
    """

    try do
      Code.compile_string(source)
      assert {:atomic, _} = apply(Examples.RetainedProgramFixture, :install, [])
      object = %AL.Object{id: :retained_program_fixture, branch: branch.id}
      assert {:ok, retained} = AL.TransactionProgram.source(object)
      assert retained =~ "retained_original"

      :code.purge(Examples.RetainedProgramFixture)
      :code.delete(Examples.RetainedProgramFixture)
      Code.compile_string(String.replace(source, "retained_original", "retained_changed"))
      assert {:ok, ^retained} = AL.TransactionProgram.source(object)

      result =
        AL.run do
          listing(:retained_program_fixture, text)
        end

      assert {:atomic, {bindings, _}} = result

      assert bindings[:"$text"] == retained

      printed =
        ExUnit.CaptureIO.capture_io(fn ->
          result =
            AL.run do
              listing(:retained_program_fixture)
            end

          assert {:atomic, _} = result
        end)

      assert printed == retained <> "\n"

      child = AL.Branch.fork(:tip, branch)

      try do
        assert {:ok, ^retained} =
                 AL.TransactionProgram.source(%AL.Object{
                   id: :retained_program_fixture,
                   branch: child.id
                 })
      after
        AL.Branch.discard(child)
      end

      assert {:atomic, _} = AL.TransactionProgram.uninstall(:retained_program_fixture)
      assert :not_program_execution = AL.TransactionProgram.source(object)
      :ok
    after
      AL.Branch.checkout(previous)
      AL.Branch.discard(branch)
      :code.purge(Examples.RetainedProgramFixture)
      :code.delete(Examples.RetainedProgramFixture)
    end
  end

  example failed_install_does_not_retain_source() do
    branch = AL.Branch.fork()
    previous = AL.Branch.head()
    AL.Branch.checkout(branch)

    try do
      tx = AL.Command.system_time(branch)

      assert {:aborted, :failed_install} =
               AL.TransactionProgram.retain_install("never committed", %{kind: :test}, fn ->
                 {:aborted, :failed_install}
               end)

      assert {:atomic, :absent} =
               :mnesia.transaction(fn -> AL.SourceStore.text(tx, branch) end)

      :ok
    after
      AL.Branch.checkout(previous)
      AL.Branch.discard(branch)
    end
  end

  defp restore_configuration(key, {:ok, value}), do: Application.put_env(:al, key, value)
  defp restore_configuration(key, :error), do: Application.delete_env(:al, key)
end
