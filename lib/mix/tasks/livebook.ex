defmodule Mix.Tasks.Livebook do
  use Mix.Task

  @shortdoc "Starts iex plus a Livebook server pointed at livebooks/"

  @moduledoc """
  Run as `bin/livebook` (a thin wrapper around `iex --name al@127.0.0.1 -S
  mix livebook`) — starts the app (same as `mix debug` needs to), then
  launches `livebook server livebooks/` as a background OS process so this
  iex session stays interactive. `--name al@127.0.0.1` (not `--sname`) is
  required: Livebook's own node always runs long-names distribution, which
  can't see a short-named node at all, so ours has to match. No `--cookie`
  override — every local process for this OS user already shares the same
  default `~/.erlang.cookie`, which is also what a fresh `mix test`/`mix
  run` uses to join this same node if it's already up (see
  `AL.Command.setup/0`); Livebook's own attach form still asks for a cookie
  explicitly, so paste whatever `cat ~/.erlang.cookie` prints (see
  livebooks/intro.livemd).

      bin/livebook

  The server's own startup output (including the browser URL, with its
  auth token) prints straight to this terminal, interleaved with the iex
  prompt.
  """

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case System.find_executable("livebook") do
      nil ->
        Mix.raise(
          "livebook executable not found on PATH — install it first (e.g. `mix escript.install hex livebook`)"
        )

      path ->
        Task.start(fn -> System.cmd(path, ["server", "livebooks/"], into: IO.stream(:stdio, :line)) end)
        :ok
    end
  end
end
