defmodule Examples.ALBitemporality do
  @moduledoc """
  I provide bitemporality feature and GIT-like behaviour examples for AL
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  
  example time_travel_fork() do
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

    AL.Object.drop_store(past)
    AL.Object.drop_store(tip)
    :ok
  end
end
