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
      program =
        AL.TransactionProgram.from_source(
          """
          defprogram transaction_program_fixture \#{version: 2, deps: [bootstrap]}.

          vm_set_class program_created_object object.
          set_slot program_created_object answer 42.
          """,
          %{kind: :transaction_program, file: "transaction_program_fixture.al"}
        )

      assert %{name: :transaction_program_fixture, version: 2, deps: [:bootstrap]} = program
      assert {:atomic, _} = AL.TransactionProgram.install(program)

      result =
        AL.run do
          ~AL"""
          class transaction_program_fixture program_execution.
          get program_created_object answer Answer.
          get transaction_program_fixture tx Transaction.
          class Transaction transaction.
          listing transaction_program_fixture Source.
          """
        end

      assert {:atomic, {bindings, _constraints, _}} = result

      assert bindings[:"$Answer"] == 42
      assert bindings[:"$Source"] =~ "set_slot program_created_object answer 42."
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
    end
  end

  example startup_uses_transaction_program_configuration() do
    old_programs = Application.fetch_env(:al, :transaction_programs)
    old_packages = Application.fetch_env(:al, :packages)

    try do
      Application.put_env(:al, :transaction_programs, [:bootstrap])
      Application.put_env(:al, :packages, [:unrelated_package_configuration])
      assert [%AL.TransactionProgram{name: :bootstrap}] = AL.TransactionProgram.configured()
      :ok
    after
      restore_configuration(:transaction_programs, old_programs)
      restore_configuration(:packages, old_packages)
    end
  end

  example listing_uses_installed_source_after_the_program_changes() do
    branch = AL.Branch.fork()
    previous = AL.Branch.head()
    AL.Branch.checkout(branch)

    source = """
    defprogram retained_program_fixture \#{version: 1, deps: []}.

    vm_set_class retained_original object.
    """

    origin = %{kind: :transaction_program, file: "retained_program_fixture.al"}

    try do
      assert {:atomic, _} =
               AL.TransactionProgram.install(AL.TransactionProgram.from_source(source, origin))

      object = %AL.Object{id: :retained_program_fixture, branch: branch.id}
      assert {:ok, ^source} = AL.TransactionProgram.source(object)

      changed =
        AL.TransactionProgram.from_source(
          String.replace(source, "retained_original", "retained_changed"),
          origin
        )

      assert changed.text != source
      assert {:ok, ^source} = AL.TransactionProgram.source(object)
      retained = source

      result =
        AL.run do
          ~AL"""
          listing retained_program_fixture Text.
          """
        end

      assert {:atomic, {bindings, _constraints, _}} = result

      assert bindings[:"$Text"] == retained

      printed =
        ExUnit.CaptureIO.capture_io(fn ->
          result =
            AL.run do
              ~AL"""
              listing retained_program_fixture.
              """
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
