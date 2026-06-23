defmodule Examples.ALBranch do
  @moduledoc """
  I provide branch (Git-like command-log fork) examples for AL: a branch is a
  divergent command log materialised into its own store.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example read_from_fork() do
    # time just before we introduce :tt_thing
    before = AL.Command.system_time()
    {:atomic, _} = run do set_class(:tt_thing, :object) end

    past = AL.Branch.fork(before - 1)
    tip = AL.Branch.fork()

    # the tip fork sees :tt_thing; the past fork does not
    {:atomic, _} = run store: tip do class(:tt_thing, :object) end
    {:aborted, _} = run store: past do class(:tt_thing, :object) end

    # both forks still carry the bootstrap
    {:atomic, _} = run store: past do class(:object, :class) end

    AL.Branch.discard(past)
    AL.Branch.discard(tip)
    :ok
  end

  example write_to_fork() do
    tip = AL.Branch.fork()

    # write only into the fork, then read it back from the fork's projection
    {:atomic, {bindings, _}} =
      run store: tip do
        set_slots(:widget, %{x: 3})
        get_slot(:widget, :x, x)
      end

    assert Map.get(bindings, :"$x") == 3

    # main never saw :widget — the write stayed in the fork's log
    {:aborted, _} = run do get_slot(:widget, :x, x) end

    AL.Branch.discard(tip)
    :ok
  end

  example checkout_switches_head() do
    branch = AL.Branch.fork()
    AL.Branch.checkout(branch)

    # with the branch checked out, plain `run` acts against it
    {:atomic, _} = run do set_class(:on_branch, :object) end
    {:atomic, _} = run do class(:on_branch, :object) end

    # back on main, the branch's write is invisible
    AL.Branch.checkout(:main)
    {:aborted, _} = run do class(:on_branch, :object) end

    AL.Branch.discard(branch)
    :ok
  end
end
