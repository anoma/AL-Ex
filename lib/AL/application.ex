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

    {:ok, pid} =
      Supervisor.start_link([AL.Scheduler.supervisor_spec(), AL.Native.Registry], opts)

    AL.Scheduler.start_all()

    bootstrap()
    register_natives()
    AL.Branch.ensure_examples()

    {:ok, pid}
  end

  def bootstrap() do
    :al
    |> Application.get_env(:packages, [])
    |> AL.Package.install_all()
  end

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
