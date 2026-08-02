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
        import(:failgreeter, :value)

        # Retract :value's imported :init pointer before overriding, or this
        # lands as another clause on :value's shared method object.
        findall(id, [vm_method(:failgreeter, :init, id)], failgreeter_init_ids)

        forall([member(failgreeter_init_ids, id)]) do
          vm_retract_method(:failgreeter, :init, id)
        end

        defmethod(:failgreeter, :init, [self, _, self]) do
        end

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

  # A failed run doesn't just report a curated summary — the actual final
  # `%AL{}` state (whatever bindings/constraints were live on the last
  # attempt, before the choicepoint stack exhausted) survives as
  # `reason.state`, so a live debugging session can inspect it directly
  # instead of only reading a linear trace of goals tried.
  example failed_run_exposes_the_final_state() do
    {:aborted, reason} =
      run branch: :examples do
        dif(x, 1)
        unify(x, 1)
      end

    assert %AL{} = reason.state
    assert reason.state.active_choicepoint.store == nil
    assert reason.state.branch.id == :examples
  end

  # `unify(a, b)` failing because a `dif`/`isa` constraint rejected it looks
  # identical to an ordinary structural mismatch in the trace alone — the next
  # goal just isn't there either way. Naming *which* constraint fired (not just
  # that some goal failed) is exactly the gap that made debugging this
  # session's own `:letter_chain` dispatch bug require throwaway `IO.inspect`s.
  example unify_failure_names_the_violated_constraint() do
    {:aborted, dif_reason} =
      run branch: :examples do
        dif(x, 1)
        unify(x, 1)
      end

    assert match?({:constraint_violated, {:dif, _, _}}, dif_reason.reason)
    assert dif_reason.message =~ "dif"

    {:aborted, isa_reason} =
      run branch: :examples do
        vm_class(y, :number)
        unify(y, :not_a_number)
      end

    assert match?({:constraint_violated, {:isa, _, :number}}, isa_reason.reason)
    assert isa_reason.message =~ "class"

    # a plain mismatch, no constraint involved, still gets the ordinary
    # generic message — this isn't claiming a constraint caused it
    {:aborted, plain_reason} =
      run branch: :examples do
        unify(1, 2)
      end

    refute match?({:constraint_violated, _}, plain_reason.reason)
  end

  # A receiver with its own does_not_understand handles the miss, so the run does
  # not abort with a does_not_understand reason.
  example custom_dnu_is_not_reported_as_failure() do
    {:atomic, _} =
      run branch: :examples do
        new(:class, %{name: :failquiet, super: :object}, _)
        import(:failquiet, :value)

        # Retract :value's imported :init pointer before overriding, or this
        # lands as another clause on :value's shared method object.
        findall(id, [vm_method(:failquiet, :init, id)], failquiet_init_ids)

        forall([member(failquiet_init_ids, id)]) do
          vm_retract_method(:failquiet, :init, id)
        end

        defmethod(:failquiet, :init, [self, _, self]) do
        end

        defmethod(:failquiet, :does_not_understand, [self, _m, _a]) do
        end

        new(:failquiet, _, q)
        anything(q, :x)
      end

    :ok
  end
end
