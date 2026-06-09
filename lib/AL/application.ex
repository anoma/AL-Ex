defmodule AL.Application do
  @moduledoc """
  I am the top level OTP application callback module for AL.
  I manage both the event server and object server.
  """

  use Application

  @impl true
  def start(_type, _args) do
    AL.Command.setup()
    AL.Objects.setup()

    opts = [strategy: :one_for_one, name: Al.Supervisor]
    {:ok, pid} = Supervisor.start_link([AL.Scheduler], opts)

    bootstrap()

    {:ok, pid}
  end

  def bootstrap() do
    case :mnesia.table_info(:command, :size) do
      0 ->
        AL.Bootstrap.Core.setup()
        AL.Bootstrap.Lists.setup()
        AL.Bootstrap.ElixirProcess.setup()
        AL.Bootstrap.Process.setup()
        AL.Bootstrap.Constraints.setup()
      _ ->
        :ok
    end
  end
end
