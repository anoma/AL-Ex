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

  defp isolated(expression, named?) do
    directory =
      Path.join(System.tmp_dir!(), "al_mnesia_example_#{System.unique_integer([:positive])}")

    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", to_string(path)] end)

    name =
      if named?, do: ["--sname", "al_example_#{System.unique_integer([:positive])}"], else: []

    try do
      {output, status} =
        System.cmd(
          System.find_executable("elixir"),
          paths ++ name ++ ["-e", expression],
          env: [
            {"AL_MNESIA_DIR", directory},
            {"AL_MNESIA_DISTRIBUTED", "true"},
            {"ERL_FLAGS", "+S 2"}
          ],
          stderr_to_stdout: true
        )

      assert status == 0, output
      :ok
    after
      File.rm_rf!(directory)
    end
  end
end
