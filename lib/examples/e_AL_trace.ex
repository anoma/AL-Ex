defmodule Examples.ALTrace do
  @moduledoc """
  I provide tracing examples for AL
  """

  use ExExample
  use AL
  import ExUnit.Assertions
  import ExUnit.CaptureIO

  example trace_object() do
    AL.trace(:cell)

    output =
      capture_io(fn ->
        run branch: :examples do
          new(:cell, %{name: :traced}, c)
        end
      end)

    AL.notrace()

    assert String.contains?(output, "Call: :cell")
    output
  end

  example trace_clause_fail() do
    AL.trace(:list_member)

    output =
      capture_io(fn ->
        run branch: :examples do
          member([:a, :b], :z)
        end
      end)

    AL.notrace()

    assert String.contains?(output, "Call:")
    assert String.contains?(output, "Fail:")
    output
  end

  # Method-level Call/Fail (above) only fires once a clause is actually
  # applied — it says nothing about *which candidate legs an unbound receiver
  # even had to try*. Tracing the selector at dispatch time shows the legs
  # offered before any of them run. `durable` deliberately reports as
  # "deferred", not a candidate count — durable candidate generation is lazy
  # (see al-clp-for-objects memory); forcing the scan just to report a count
  # here would undo that.
  example trace_shows_dispatch_legs() do
    {:atomic, _} =
      run branch: :examples do
        new(:class, %{name: :trace_leg_class, super: :value, ivars: []}, _)

        defmethod(:trace_leg_class, :trace_next, [:a, :b])
      end

    AL.trace(:trace_next)

    output =
      capture_io(fn ->
        run branch: :examples do
          trace_next(x, :b)
        end
      end)

    AL.notrace()

    assert String.contains?(output, "Dispatch: ")
    assert String.contains?(output, "value=[:trace_leg_class]")
    assert String.contains?(output, "durable=deferred")
  end

  example failing_query_renders_struct_trace() do
    result =
      run branch: :examples do
        member([:a, :b], :z)
      end

    assert {:aborted, %{failed_on: _, trace: trace}} = result
    assert is_list(trace)
    result
  end
end
