import Config

config :logger,
  level: :error

config :al,
  serialisation_dir: nil

config :al, AL.MCP, enabled: false
