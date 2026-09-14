defmodule Mix.Tasks.Al.Reset do
  use Mix.Task

  @shortdoc "Wipes the local Mnesia store (.mnesiastore/) so boot reinstalls every transaction program fresh"

  @moduledoc """
  Deletes #{AL.Command.mnesia_dir()} and the configured AL serialisation tree,
  the disposable state shared by every `mix run`/`mix test` in this checkout.
  Both are rebuilt from scratch on next boot.

  This is a genuinely destructive, process-wide reset — it takes out `:main`
  *and every fork*, including any other node's, not just yours. Prefer
  working on a throwaway fork (`AL.Branch.fork/2` ... `discard/1`) day to
  day; forks are safely isolated from each other and from concurrent nodes
  without needing this at all (verified: two independent `mix run`
  processes, each only forking/writing/discarding its own branch, don't
  conflict — see al-bounds-consistency memory). Reach for this only when a
  fork can't fix it — typically a VM-level goal-encoding change (new arity,
  a new sentinel), where old-shape commands already in the log can no longer
  replay. Coordinate before running it if anyone else might have a node up.

      mix al.reset          # asks first
      mix al.reset --yes    # skips the prompt
  """

  @impl Mix.Task
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, aliases: [y: :yes], strict: [yes: :boolean])
    dir = AL.Command.mnesia_dir()
    serialisation_dir = AL.Serialisation.configured_root()
    paths = [dir, serialisation_dir] |> Enum.reject(&is_nil/1) |> Enum.uniq()
    existing = Enum.filter(paths, &File.exists?/1)

    cond do
      existing == [] ->
        Mix.shell().info("#{Enum.join(paths, " and ")} don't exist — already clean.")

      opts[:yes] ||
          Mix.shell().yes?(
            "Delete #{Enum.join(existing, " and ")}? This affects every fork, every node."
          ) ->
        Enum.each(existing, &File.rm_rf!/1)

        Mix.shell().info(
          "Deleted #{Enum.join(existing, " and ")}. Next boot reinstalls every transaction program fresh."
        )

      true ->
        Mix.shell().info("Aborted.")
    end
  end
end
