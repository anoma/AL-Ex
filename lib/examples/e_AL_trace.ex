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
