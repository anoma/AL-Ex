defmodule AL.JAM.Trace do
  @key :al_jam_trace

  def tracing?(trace),
    do: AL.Trace.retained?(trace) or MapSet.size(trace.runtime.tracepoints) > 0

  def run(trace, fun) do
    if tracing?(trace) do
      previous = Process.put(@key, trace)

      try do
        result = fun.()
        {result, Process.get(@key)}
      after
        if is_nil(previous), do: Process.delete(@key), else: Process.put(@key, previous)
      end
    else
      {fun.(), trace}
    end
  end

  def active?, do: Process.get(@key) != nil

  def scope_of({:traced, scope, _seq, _id}), do: scope
  def scope_of({:cut_scope, _ref, id}), do: scope_of(id)
  def scope_of({:root, scope}), do: scope
  def scope_of(_id), do: nil

  def parent(id), do: scope_of(id) || 0

  def seq_of({:traced, _scope, seq, _id}), do: seq
  def seq_of({:cut_scope, _ref, id}), do: seq_of(id)
  def seq_of(_id), do: nil

  def returned({:traced, scope, _seq, id}), do: {:traced, scope, nil, id}
  def returned({:cut_scope, ref, id}), do: {:cut_scope, ref, returned(id)}
  def returned(id), do: id

  def depth(returns), do: Enum.count(returns, &match?({:trace_exit, _}, &1))

  def method_call(parent, receiver, method, args, store, depth) do
    scope = AL.fresh_scope()
    open = AL.Answer.open_positions(AL.Answer.call_positions(receiver, args), store)

    update(fn trace ->
      trace
      |> port_call(:method, scope, receiver, method, args, depth)
      |> push(
        {:method_call, scope, receiver, method, args, AL.Answer.describe_positions(open, store)}
      )
      |> put_scope(scope, %{
        parent: parent,
        kind: :method,
        open_vars: open,
        exited: false,
        derived: nil
      })
    end)

    scope
  end

  def clause_call(parent, method, call, store, depth) do
    scope = AL.fresh_scope()

    {receiver, args} =
      case call do
        [receiver | args] -> {receiver, args}
        other -> {other, []}
      end

    open = AL.Answer.open_positions(AL.Answer.call_positions(receiver, args), store)

    update(fn trace ->
      trace
      |> port_call(:clause, scope, receiver, method, args, depth)
      |> push({:clause_call, scope, method, call, AL.Answer.describe_positions(open, store)})
      |> put_scope(scope, %{
        parent: parent,
        kind: :clause,
        open_vars: open,
        exited: false,
        derived: nil
      })
    end)

    scope
  end

  def dispatch(receiver, method, branch) do
    case Process.get(@key) do
      %AL.Trace{runtime: %AL.Trace.Runtime{tracepoints: points}} ->
        if not AL.Var.var?(method) and MapSet.member?(points, method),
          do:
            AL.Trace.dispatch(receiver, method, AL.Dispatch.open_provider_classes(method, branch))

      nil ->
        :ok
    end

    :ok
  end

  def chosen(scope, seq), do: update(&push(&1, {:clause_chosen, scope, seq}))

  def exit(scope, store), do: update(&mark_exited(&1, scope, store))

  def fail(scope, tag) do
    update(fn trace ->
      trace
      |> port_event(scope, :fail)
      |> push({tag, scope})
      |> delete_scope(scope)
    end)
  end

  def resume(scope) do
    update(fn trace ->
      trace =
        case Map.get(trace.runtime.scopes, scope) do
          %{exited: true, kind: kind} ->
            tag = if kind == :method, do: :method_redo, else: :clause_redo
            trace |> port_event(scope, :redo) |> push({tag, scope})

          _ ->
            trace
        end

      trace |> AL.Trace.push(:vm, :backtrack) |> unmark_exited(scope)
    end)
  end

  def goal(goal, store) do
    update(fn trace ->
      trace = finish_constraint(trace, store)

      cond do
        not AL.Trace.retained?(trace) ->
          trace

        constraint_goal?(goal) and AL.Trace.enabled?(trace, :domino) ->
          vars = AL.Var.find_vars(goal)

          pending = %{
            goal: goal,
            vars: vars,
            constraints_in: AL.Answer.describe_positions(vars, store)
          }

          runtime = %AL.Trace.Runtime{trace.runtime | pending_constraint: pending}
          %AL.Trace{trace | runtime: runtime}

        true ->
          AL.Trace.push(trace, :vm, goal)
      end
    end)
  end

  def settle(store), do: update(&finish_constraint(&1, store))

  def abandon do
    update(fn trace ->
      %AL.Trace{trace | runtime: %AL.Trace.Runtime{trace.runtime | pending_constraint: nil}}
    end)
  end

  def flounder, do: update(&AL.Trace.push(&1, :vm, :flounder))

  def collection(kind, condition, output, fun) do
    outer = Process.get(@key)
    scope = AL.fresh_scope()
    child = AL.Trace.new(outer.flags)

    Process.put(@key, %AL.Trace{
      child
      | runtime: %AL.Trace.Runtime{child.runtime | tracepoints: outer.runtime.tracepoints}
    })

    try do
      result = fun.(scope)
      inner = finalize(Process.get(@key))

      events =
        if AL.Trace.enabled?(inner, :domino) do
          [
            %AL.Trace.Event{kind: :domino, payload: {:collection_end, scope}}
            | inner.events
          ] ++
            [
              %AL.Trace.Event{
                kind: :domino,
                payload: {:collection_begin, scope, kind, condition, output}
              }
            ]
        else
          inner.events
        end

      Process.put(@key, %AL.Trace{outer | events: events ++ outer.events})
      result
    rescue
      error ->
        Process.put(@key, outer)
        reraise error, __STACKTRACE__
    end
  end

  def solution(scope, store), do: update(&push(&1, {:collection_solution, scope, store}))

  def finalize(trace) do
    if AL.Trace.enabled?(trace, :domino) do
      {events, _patched} =
        Enum.map_reduce(trace.events, MapSet.new(), fn
          %AL.Trace.Event{kind: :domino, payload: {tag, scope, _old}} = event, patched
          when tag in [:method_exit, :clause_exit] ->
            key = {tag, scope}

            cond do
              MapSet.member?(patched, key) ->
                {event, patched}

              match?(
                %{derived: derived} when not is_nil(derived),
                Map.get(trace.runtime.scopes, scope)
              ) ->
                %{derived: derived} = Map.get(trace.runtime.scopes, scope)

                {%AL.Trace.Event{event | payload: {tag, scope, derived}},
                 MapSet.put(patched, key)}

              true ->
                {event, MapSet.put(patched, key)}
            end

          other, patched ->
            {other, patched}
        end)

      %AL.Trace{trace | events: events}
    else
      runtime = %AL.Trace.Runtime{trace.runtime | scopes: %{}, traced_calls: %{}}
      %AL.Trace{trace | runtime: runtime}
    end
  end

  defp update(fun) do
    case Process.get(@key) do
      nil -> :ok
      trace -> Process.put(@key, fun.(trace))
    end

    :ok
  end

  defp push(trace, event), do: AL.Trace.push(trace, :domino, event)

  defp scopes?(trace),
    do: AL.Trace.enabled?(trace, :domino) or MapSet.size(trace.runtime.tracepoints) > 0

  defp put_scope(trace, scope, info) do
    if scopes?(trace),
      do: %AL.Trace{
        trace
        | runtime: %AL.Trace.Runtime{
            trace.runtime
            | scopes: Map.put(trace.runtime.scopes, scope, info)
          }
      },
      else: trace
  end

  defp delete_scope(trace, scope),
    do: %AL.Trace{
      trace
      | runtime: %AL.Trace.Runtime{
          trace.runtime
          | scopes: Map.delete(trace.runtime.scopes, scope)
        }
    }

  defp mark_exited(trace, scope, store) do
    case Map.get(trace.runtime.scopes, scope) do
      nil ->
        trace

      %{kind: kind, open_vars: open, exited: exited?} = info ->
        tag = if kind == :method, do: :method_exit, else: :clause_exit
        derived = AL.Answer.describe_positions(open, store)

        trace =
          if exited?,
            do: put_scope(trace, scope, %{info | derived: derived}),
            else:
              trace
              |> port_event(scope, :exit)
              |> push({tag, scope, derived})
              |> put_scope(scope, %{info | exited: true, derived: derived})

        case Map.get(trace.runtime.scopes, info.parent) do
          %{kind: :method} -> mark_exited(trace, info.parent, store)
          _ -> trace
        end
    end
  end

  defp unmark_exited(trace, scope) do
    case Map.get(trace.runtime.scopes, scope) do
      %{exited: true, parent: parent} = info ->
        trace |> put_scope(scope, %{info | exited: false}) |> unmark_exited(parent)

      _ ->
        trace
    end
  end

  defp finish_constraint(
         %AL.Trace{runtime: %AL.Trace.Runtime{pending_constraint: nil}} = trace,
         _store
       ),
       do: trace

  defp finish_constraint(trace, store) do
    %{goal: goal, vars: vars, constraints_in: constraints_in} = trace.runtime.pending_constraint
    derived = AL.Answer.describe_positions(vars, store)
    trace = %AL.Trace{trace | runtime: %AL.Trace.Runtime{trace.runtime | pending_constraint: nil}}
    push(trace, {:constraint, goal, constraints_in, derived})
  end

  defp port_call(trace, level, scope, receiver, method, args, depth) do
    if MapSet.member?(trace.runtime.tracepoints, method) or
         MapSet.member?(trace.runtime.tracepoints, receiver) do
      AL.Trace.call(level, depth, receiver, method, args)
      calls = Map.put(trace.runtime.traced_calls, scope, {level, depth, receiver, method})
      %AL.Trace{trace | runtime: %AL.Trace.Runtime{trace.runtime | traced_calls: calls}}
    else
      trace
    end
  end

  defp port_event(trace, scope, kind) do
    case Map.get(trace.runtime.traced_calls, scope) do
      nil ->
        trace

      {level, depth, receiver, method} ->
        case kind do
          :exit -> AL.Trace.exit(level, depth, receiver, method)
          :redo -> AL.Trace.redo(level, depth, receiver, method)
          :fail -> AL.Trace.fail(level, depth, receiver, method)
        end

        if kind == :fail do
          calls = Map.delete(trace.runtime.traced_calls, scope)
          %AL.Trace{trace | runtime: %AL.Trace.Runtime{trace.runtime | traced_calls: calls}}
        else
          trace
        end
    end
  end

  defp constraint_goal?(%AL.Goal.Compare{}), do: true
  defp constraint_goal?(%AL.Goal.FloorDivide{}), do: true

  defp constraint_goal?(%AL.Goal.Eq{a: a, b: b}),
    do: AL.Var.Bounds.arithmetic?(a) or AL.Var.Bounds.arithmetic?(b)

  defp constraint_goal?(%AL.Goal.Dif{}), do: true
  defp constraint_goal?(%AL.Goal.Isa{}), do: true
  defp constraint_goal?(%AL.Goal.AllDif{}), do: true
  defp constraint_goal?(%AL.Goal.InDomain{}), do: true
  defp constraint_goal?(_goal), do: false
end
