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

    bootstrap()
    AL.Branch.ensure_examples()
    AL.Serialisation.start_all()

    {:ok, pid}
  end

  def bootstrap() do
    packages_pending? = not AL.Package.system_available?()

    programs =
      AL.TransactionProgram.configured()
      |> Enum.reject(fn module ->
        Code.ensure_loaded!(module)
        program = module.__program__()
        AL.TransactionProgram.current?(program.name, program.version)
      end)

    :ok = install_startup(programs, packages_pending?)
    register_natives()
  end

  defp install_startup([], false), do: :ok

  defp install_startup(programs, packages_pending?) do
    ready_programs =
      Enum.filter(programs, fn module ->
        Enum.all?(module.__program__().deps, &dependency_installed?/1)
      end)

    packages_ready? = packages_pending? and AL.Package.system_available?()

    if ready_programs == [] and not packages_ready? do
      program_names = Enum.map(programs, & &1.__program__().name)
      package_names = AL.Package.configured_environment()

      raise "AL startup dependencies cannot be satisfied: programs #{inspect(program_names)}, packages #{inspect(package_names)}"
    end

    Enum.each(ready_programs, fn module ->
      program = module.__program__()
      :ok = AL.TransactionProgram.ensure_current(program.name, program.version, &module.install/0)
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
