import Config

config :logger,
  level: :error,
  handle_otp_reports: false,
  handle_sasl_reports: false

# Packages installed at startup.
config :al,
  packages: [
    AL.Package.Bootstrap,
    AL.Package.Users,
    AL.Package.ElixirProcess,
    AL.Package.Mapset,
    AL.Package.Interval,
    AL.Package.Constraints,
    AL.Package.Equations,
    AL.Package.Sudoku,
    AL.Package.Blackjack
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
if File.exists?("config/#{config_env()}.exs") do
  import_config "#{config_env()}.exs"
end
