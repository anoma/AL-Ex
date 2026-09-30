import Config

if is_nil(System.get_env("AL_MNESIA_DIR")) do
  test_mnesia_dir =
    Path.join(
      System.tmp_dir!(),
      "al-mix-test-#{System.pid()}-#{System.unique_integer([:positive])}"
    )

  File.mkdir_p!(test_mnesia_dir)
  System.put_env("AL_MNESIA_DIR", test_mnesia_dir)
  System.at_exit(fn _ -> File.rm_rf(test_mnesia_dir) end)
end

if is_nil(System.get_env("AL_MNESIA_DISTRIBUTED")) do
  System.put_env("AL_MNESIA_DISTRIBUTED", "false")
end

config :logger,
  level: :error

config :al,
  serialisation_dir: nil,
  create_examples_branch: false

config :al, AL.MCP, enabled: false
