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

  # Call/Fail only fires once a clause applies -- says nothing about which
  # candidate legs an unbound receiver tried. Selector trace shows legs before
  # any run. durable reports "deferred" not a count -- scanning to report one
  # would force the lazy scan it's meant to avoid.
  example trace_shows_dispatch_legs() do
    {:atomic, _} =
      run branch: :examples do
        defclass :trace_leg_class, super: :value, ivars: [] do
          defmethod(:trace_next, [
            %{class: :trace_leg_class, letter: :a},
            %{class: :trace_leg_class, letter: :b}
          ])
        end
      end

    AL.trace(:trace_next)

    output =
      capture_io(fn ->
        run branch: :examples do
          trace_next(x, %{class: :trace_leg_class, letter: :b})
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
