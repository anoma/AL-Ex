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
    {:ok, pid} = Supervisor.start_link([AL.Scheduler], opts)

    bootstrap()

    {:ok, pid}
  end

  def bootstrap() do
    :al
    |> Application.get_env(:packages, [])
    |> AL.Package.install_all()
  end
end
