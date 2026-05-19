import Config

config :logger,
  level: :error,
  handle_otp_reports: false,
  handle_sasl_reports: false

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
if File.exists?("config/#{config_env()}.exs") do
  import_config "#{config_env()}.exs"
end
