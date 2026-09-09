defmodule AL.Application do
  @moduledoc """
  I am the top level OTP application callback module for AL.
  I manage both the event server and object server.
  """

  use Application

  @impl true
  def start(_type, _args) do
    AL.Command.setup()
    AL.Branch.setup()

    opts = [strategy: :one_for_one, name: Al.Supervisor]

    children = [
      AL.Scheduler.supervisor_spec(),
      AL.Serialisation.supervisor_spec(),
      AL.Native.Registry
    ]

    children = if AL.MCP.enabled?(), do: children ++ [AL.MCP], else: children

    {:ok, pid} = Supervisor.start_link(children, opts)

    AL.Scheduler.start_all()

    bootstrap()
    register_natives()
    AL.Branch.ensure_examples()
    AL.Serialisation.start_all()

    {:ok, pid}
  end

  def bootstrap() do
    programs =
      AL.TransactionProgram.configured()
      |> Enum.reject(fn module ->
        Code.ensure_loaded!(module)
        program = module.__program__()
        AL.TransactionProgram.current?(program.name, program.version)
      end)

    packages =
      AL.Package.configured()
      |> Enum.map(fn path ->
        case AL.Package.manifest(path) do
          {:ok, document} -> {path, document}
          {:error, reason} -> raise "AL package manifest #{path} is invalid: #{inspect(reason)}"
        end
      end)
      |> Enum.reject(fn {_path, document} -> AL.Package.installed?(document.name) end)

    install_startup(programs, packages)
  end

  defp install_startup([], []), do: :ok

  defp install_startup(programs, packages) do
    ready_programs =
      Enum.filter(programs, fn module ->
        Enum.all?(module.__program__().deps, &dependency_installed?/1)
      end)

    ready_packages = Enum.filter(packages, fn {path, _document} -> AL.Package.ready?(path) end)

    if ready_programs == [] and ready_packages == [] do
      program_names = Enum.map(programs, & &1.__program__().name)
      package_names = Enum.map(packages, fn {_path, document} -> document.name end)

      raise "AL startup dependencies cannot be satisfied: programs #{inspect(program_names)}, packages #{inspect(package_names)}"
    end

    Enum.each(ready_programs, fn module ->
      program = module.__program__()
      :ok = AL.TransactionProgram.ensure_current(program.name, program.version, &module.install/0)
    end)

    Enum.each(ready_packages, fn {path, document} ->
      case AL.Package.ensure_imported(path) do
        :ok ->
          :ok

        {:error, reason} ->
          raise "AL package #{inspect(document.name)} failed to import: #{inspect(reason)}"
      end
    end)

    install_startup(programs -- ready_programs, packages -- ready_packages)
  end

  defp dependency_installed?(name),
    do: AL.TransactionProgram.installed?(name) or AL.Package.installed?(name)

  # Re-run on every boot, same as bootstrap/0 -- a native's durable binding
  # fact survives an image restart, but the implementation itself doesn't
  # (see AL.Native); this is what re-satisfies it automatically instead of
  # requiring anyone to remember a manual re-registration step.
  def register_natives() do
    :al
    |> Application.get_env(:natives, [])
    |> AL.Native.register_all()
  end
end
