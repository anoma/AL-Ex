defmodule AL.MCP do
  @moduledoc "An in-process MCP endpoint for working with the live AL node."

  use Supervisor

  @default_options [enabled: true, ip: {127, 0, 0, 1}, port: 3031]

  @spec enabled?() :: boolean()
  def enabled? do
    Keyword.get(options(), :enabled, true) and node() == AL.Command.owner_node()
  end

  def start_link(options) do
    Supervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(overrides) do
    options = Keyword.merge(options(), overrides)

    children = [
      AL.MCP.Contexts,
      {Plug.Cowboy,
       scheme: :http,
       plug: AL.MCP.Router,
       options: [
         ip: Keyword.fetch!(options, :ip),
         port: Keyword.fetch!(options, :port),
         ref: __MODULE__
       ]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec options() :: keyword()
  def options do
    Keyword.merge(@default_options, Application.get_env(:al, __MODULE__, []))
  end
end
