defmodule Examples.ALMnesia do
  use ExExample
  import ExUnit.Assertions

  example named_node_owns_its_tables() do
    isolated(
      """
      :ok = AL.Command.setup()
      true = AL.Command.owner_node() == node()
      for table <- [:command, :meta] do
        true = :mnesia.table_info(table, :disc_copies) == [node()]
      end
      {:ok, _} = AL.Command.create_tables(AL.Branch.main())
      :stopped = :mnesia.stop()
      :ok = AL.Command.setup()
      true = AL.Command.owner_node() == node()
      """,
      true
    )
  end

  example table_creation_reports_abort() do
    isolated(
      """
      try do
        AL.Command.create_tables(AL.Branch.main())
        raise "expected table creation to fail"
      rescue
        error in AL.Command.TableCreationError ->
          :command = error.table
          {:node_not_running, _} = error.reason
      end
      """,
      false
    )
  end

  example short_named_nodes_keep_separate_default_stores() do
    checkout = scratch_directory()
    File.mkdir_p!(checkout)

    try do
      for _ <- 1..2 do
        output =
          run(
            """
            :ok = AL.Command.setup()
            true = AL.Command.owner_node() == node()
            true = AL.Command.mnesia_dir() == ".mnesiastore-\#{node()}/"
            true = :mnesia.table_info(:command, :disc_copies) == [node()]
            """,
            name: unique_name(),
            cd: checkout,
            env: [{"AL_MNESIA_DIR", nil}]
          )

        refute output =~ "Hostname 127.0.0.1 is illegal", output
      end

      false = File.exists?(Path.join(checkout, ".mnesiastore"))
      :ok
    after
      File.rm_rf!(checkout)
    end
  end

  defp isolated(expression, named?) do
    directory = scratch_directory()
    name = if named?, do: [name: unique_name()], else: []

    try do
      run(expression, [cd: File.cwd!(), env: [{"AL_MNESIA_DIR", directory}]] ++ name)
      :ok
    after
      File.rm_rf!(directory)
    end
  end

  defp run(expression, options) do
    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", to_string(path)] end)
    name = if node = options[:name], do: ["--sname", node], else: []
    directory = scratch_directory()
    File.mkdir_p!(directory)
    script = Path.join(directory, "example.exs")
    File.write!(script, expression)

    try do
      {output, status} =
        System.cmd(
          System.find_executable("elixir"),
          paths ++ name ++ [script],
          cd: options[:cd],
          env: [{"AL_MNESIA_DISTRIBUTED", "true"}, {"ERL_FLAGS", "+S 2"} | options[:env]],
          stderr_to_stdout: true
        )

      assert status == 0, output
      output
    after
      File.rm_rf!(directory)
    end
  end

  defp scratch_directory(),
    do: Path.join(System.tmp_dir!(), "al_mnesia_example_#{System.unique_integer([:positive])}")

  defp unique_name(), do: "al_example_#{System.unique_integer([:positive])}"
end
