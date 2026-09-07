defmodule AL.MCP do
  @moduledoc "An in-process MCP endpoint for working with the live AL node."

  @default_options [enabled: true, ip: {127, 0, 0, 1}, port: 3031]

  @spec enabled?() :: boolean()
  def enabled? do
    Keyword.get(options(), :enabled, true) and node() == AL.Command.owner_node()
  end

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg) do
    options = options()

    Plug.Cowboy.child_spec(
      scheme: :http,
      plug: AL.MCP.Router,
      options: [
        ip: Keyword.fetch!(options, :ip),
        port: Keyword.fetch!(options, :port),
        ref: __MODULE__
      ]
    )
  end

  @spec options() :: keyword()
  def options do
    Keyword.merge(@default_options, Application.get_env(:al, __MODULE__, []))
  end
end
