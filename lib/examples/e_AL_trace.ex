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
    output = capture_io(fn -> run do new(:cell, %{name: :traced}, c) end end)
    AL.notrace()

    assert String.contains?(output, "Call: :cell")
    output
  end

  example trace_clause_fail() do
    AL.trace(:list_member)
    output = capture_io(fn -> run do member([:a, :b], :z) end end)
    AL.notrace()

    assert String.contains?(output, "Call:")
    assert String.contains?(output, "Fail:")
    output
  end
end
