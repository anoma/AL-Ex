import Config

config :logger,
  level: :error,
  handle_otp_reports: false,
  handle_sasl_reports: false

config :al,
  serialisation_dir: "src/al",
  transaction_programs: [
    AL.TransactionProgram.Bootstrap,
    AL.TransactionProgram.PackageSystem,
    AL.TransactionProgram.Mapset,
    AL.TransactionProgram.Constraints,
    AL.TransactionProgram.Sudoku,
    AL.TransactionProgram.Blackjack,
    AL.TransactionProgram.Euler
  ],
  package_channels: [
    {:builtin, {:priv, "packages"}}
  ],
  package_environment: [
    :interval,
    :users,
    :elixir_process
  ]

# Native (Elixir-backed) methods registered at every boot -- see AL.Native.
# {class, selector, module, function, arity} or {..., opts} tuples.
config :al, natives: []

config :al, AL.MCP,
  enabled: true,
  ip: {127, 0, 0, 1},
  port: 3031

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
if File.exists?("config/#{config_env()}.exs") do
  import_config "#{config_env()}.exs"
end
