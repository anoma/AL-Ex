defmodule Mix.Tasks.Debug do
  use Mix.Task

  @shortdoc "Starts iex with inspect output tuned for reading raw AL state"

  @moduledoc """
  Run as `iex -S mix debug` — an ordinary `iex -S mix` session (so
  `.iex.exs` still loads: `run`, `defmethod`, the module aliases, and the
  `:al` OTP app itself, Mnesia included), plus two `IEx.configure/1` tweaks
  aimed at inspecting a `%AL{}`/`.domino.trace` by hand instead of through a
  formatter:

    - `limit: :infinity` — no truncation, so a long `trace` or a deeply
      nested constraint map prints in full instead of `...`-ing partway
      through.
    - `charlists: :as_lists` — a list of small integers (e.g. a scope-id
      list, or any plain `[1, 2, 3]`-shaped term that happens to also be
      printable as one) always renders as a list of numbers, never
      auto-detected as a `'charlist'` literal.

      iex -S mix debug

  Unlike plain `iex -S mix`, invoking an arbitrary custom task this way
  does *not* start the current project's OTP application for free — only
  `Mix.Task.run("app.start")` does that, so it's called explicitly here
  first. Skipping it is exactly what breaks `AL.run` with
  `{:node_not_running, :nonode@nohost}`: `AL.Command.setup/0` (which
  creates the Mnesia schema and calls `:mnesia.start/0`) lives in
  `AL.Application.start/2` and never runs otherwise.
  """

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    IEx.configure(inspect: [limit: :infinity, charlists: :as_lists])
  end
end
