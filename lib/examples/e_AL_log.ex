defmodule Examples.ALLog do
  @moduledoc """
  I provide command-log forking (Git-like) examples for AL: a `fork` is a
  divergent command log materialised into its own store.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example read_from_fork() do
    # time just before we introduce :tt_thing
    before = AL.Command.system_time()
    {:atomic, _} = run do set_class(:tt_thing, :object) end

    past = AL.Object.fork(before - 1)
    tip = AL.Object.fork()

    # the tip fork sees :tt_thing; the past fork does not
    {:atomic, _} = run store: tip do class(:tt_thing, :object) end
    {:aborted, _} = run store: past do class(:tt_thing, :object) end

    # both forks still carry the bootstrap
    {:atomic, _} = run store: past do class(:object, :class) end

    AL.Object.discard(past)
    AL.Object.discard(tip)
    :ok
  end

  example write_to_fork() do
    tip = AL.Object.fork()

    # write only into the fork, then read it back from the fork's projection
    {:atomic, {bindings, _}} =
      run store: tip do
        set_slots(:widget, %{x: 3})
        get_slot(:widget, :x, x)
      end

    assert Map.get(bindings, :"$x") == 3

    # main never saw :widget — the write stayed in the fork's log
    {:aborted, _} = run do get_slot(:widget, :x, x) end

    AL.Object.discard(tip)
    :ok
  end
end
