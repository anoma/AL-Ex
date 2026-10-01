defmodule AL.Application do
  @moduledoc """
  I start AL's durable stores, branch services, host edges, and runtime registries.
  """

  use Application

  @impl true
  def start(_type, _args) do
    AL.Command.setup()
    AL.Branch.setup()

    opts = [strategy: :one_for_one, name: Al.Supervisor]

    children = [
      AL.Events,
      AL.Outbox.supervisor_spec(),
      AL.Serialisation.supervisor_spec(),
      AL.Native.Registry,
      AL.Edge.Registry,
      AL.Edge.File,
      AL.Edge.TCP
    ]

    children = if AL.MCP.enabled?(), do: children ++ [AL.MCP], else: children

    {:ok, pid} = Supervisor.start_link(children, opts)

    register_edge_providers()
    AL.Outbox.start_all()

    main_time = AL.Command.system_time(AL.Branch.main())
    bootstrap()

    if Application.get_env(:al, :create_examples_branch, true) do
      if AL.Command.system_time(AL.Branch.main()) == main_time,
        do: AL.Branch.ensure_examples(),
        else: AL.Branch.reset_examples_to(:tip)
    end

    AL.Serialisation.start_all()

    {:ok, pid}
  end

  def bootstrap() do
    programs =
      Enum.reject(AL.TransactionProgram.configured(), &AL.TransactionProgram.installed?(&1.name))

    packages_pending? =
      not (AL.Package.system_available?() and AL.Package.configured_current?())

    :ok = install_startup(programs, packages_pending?)
    register_natives()
  end

  defp install_startup([], false), do: :ok

  defp install_startup(programs, packages_pending?) do
    ready_programs =
      Enum.filter(programs, fn program ->
        Enum.all?(program.deps, &dependency_installed?/1)
      end)

    packages_ready? = packages_pending? and AL.Package.system_available?()

    if ready_programs == [] and not packages_ready? do
      program_names = Enum.map(programs, & &1.name)
      package_names = AL.Package.configured_environment()

      raise "AL startup dependencies cannot be satisfied: programs #{inspect(program_names)}, packages #{inspect(package_names)}"
    end

    Enum.each(ready_programs, fn program ->
      :ok = AL.TransactionProgram.ensure_installed(program)
    end)

    if packages_ready? do
      case AL.Package.ensure_configured() do
        :ok ->
          :ok

        {:error, reason} ->
          raise "AL package environment failed to activate: #{inspect(reason)}"
      end
    end

    install_startup(programs -- ready_programs, packages_pending? and not packages_ready?)
  end

  defp dependency_installed?(name),
    do: AL.TransactionProgram.installed?(name) or AL.Package.active?(name)

  # Re-run on every boot, same as bootstrap/0 -- a native's durable binding
  # fact survives an image restart, but the implementation itself doesn't
  # (see AL.Native); this is what re-satisfies it automatically instead of
  # requiring anyone to remember a manual re-registration step.
  def register_natives() do
    :al
    |> Application.get_env(:natives, [])
    |> AL.Native.register_all()
  end

  def register_edge_providers() do
    :al
    |> Application.get_env(:edge_providers, [])
    |> AL.Edge.register_all()
  end
end
