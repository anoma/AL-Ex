import Config

config :logger,
  level: :error

config :al, mnesia_storage: :ram_copies
