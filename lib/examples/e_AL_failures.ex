defmodule Examples.ALFailures do
  @moduledoc """
  I provide examples for AL's failure reporting: when a run aborts, the reason it
  carries should be legible — naming the message that wasn't understood and
  offering a suggestion — rather than a bare goal dump.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  # A directed send of an unknown selector, on a receiver with no custom
  # does_not_understand, aborts with a structured `:does_not_understand` reason
  # naming the receiver, selector, arity, and a ranked suggestion.
  example unknown_selector_reports_does_not_understand() do
    {:aborted, reason} =
      run branch: :examples do
        new(:class, %{name: :failgreeter, super: :object}, _)
        import(:failgreeter, :ephemeral)

        defmethod(:failgreeter, :greet, [self, _name]) do
        end

        new(:failgreeter, _, g)
        greett(g, :world)
      end

    assert match?(
             {:does_not_understand, %{class: :failgreeter}, :greett, 1, _suggestions},
             reason.reason
           )

    {:does_not_understand, _recv, _sel, _arity, suggestions} = reason.reason
    assert hd(suggestions) == :greet
    assert reason.message =~ "does not understand"
    assert reason.message =~ "greet"
    :ok
  end

  # A plain goal failure (no unhandled message) still aborts, and its trace is
  # free of internal `:backtrack` noise.
  example plain_failure_trace_omits_backtracks() do
    {:aborted, reason} =
      run branch: :examples do
        vm_class(:no_such_object_al_failures, c)
      end

    refute :backtrack in reason.trace
    :ok
  end

  # A receiver with its own does_not_understand handles the miss, so the run does
  # not abort with a does_not_understand reason.
  example custom_dnu_is_not_reported_as_failure() do
    {:atomic, _} =
      run branch: :examples do
        new(:class, %{name: :failquiet, super: :object}, _)
        import(:failquiet, :ephemeral)

        defmethod(:failquiet, :does_not_understand, [self, _m, _a]) do
        end

        new(:failquiet, _, q)
        anything(q, :x)
      end

    :ok
  end
end
