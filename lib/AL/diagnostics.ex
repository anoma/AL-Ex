defmodule AL.Diagnostics do
  def format_failure(%AL{diagnostics: [{:resource_limit_exceeded, limit} | _]} = state) do
    raw_tail =
      if AL.Trace.retained?(state.trace),
        do: last_raw_steps(state.trace.events, 20),
        else: []

    steps = Enum.map(raw_tail, &AL.Trace.pretty/1)
    failed_on = steps |> List.last() |> AL.Trace.payload() || current_failure(state)

    %{
      message:
        "Resource limit exceeded after #{limit} reduction steps — likely infinite " <>
          "backtracking (a generative send with no termination guarantee).",
      reason: {:resource_limit_exceeded, limit},
      failed_on: failed_on,
      trace: steps,
      state: %AL{
        state
        | trace: %AL.Trace{state.trace | events: raw_tail},
          choicepoint_stack: []
      }
    }
  end

  def format_failure(state) do
    if AL.Trace.enabled?(state.trace, :domino),
      do: format_domino_failure(state),
      else: format_compact_failure(state)
  end

  defp format_compact_failure(state) do
    steps = state.trace.events |> Enum.reverse() |> Enum.map(&AL.Trace.pretty/1)
    failed_on = steps |> List.last() |> AL.Trace.payload() || current_failure(state)

    {message, reason} =
      case state.failure_candidate do
        {_score, {:diagnostic, diagnostic}} ->
          failure_cause([diagnostic], MapSet.new(), failed_on, state)

        {_score, {:call, call}} ->
          failure_from_call(call, failed_on)

        nil ->
          failure_from_call(nil, failed_on)
      end

    %{
      message: message,
      reason: reason,
      failed_on: failed_on,
      trace: steps,
      state: state
    }
  end

  defp format_domino_failure(state) do
    steps = state.trace.events |> Enum.reverse() |> Enum.map(&AL.Trace.pretty/1)
    failed_on = steps |> List.last() |> AL.Trace.payload()
    ancestry = failing_lineage(state.trace.events)

    relevant_diagnostics =
      state.diagnostics
      |> Enum.filter(fn {scope, _inner} -> MapSet.member?(ancestry, scope) end)
      |> Enum.map(fn {_scope, inner} -> inner end)
      |> Enum.uniq()

    {message, reason} = failure_cause(relevant_diagnostics, ancestry, failed_on, state)

    %{
      message: message,
      reason: reason,
      failed_on: failed_on,
      trace: steps,
      state: state
    }
  end

  defp failure_cause([{receiver, selector, arity, branch} | _], _ancestry, _failed_on, _state) do
    suggestions = AL.Dispatch.suggest(receiver, selector, branch)
    receiver = AL.Trace.pretty(receiver)

    hint =
      case suggestions do
        [top | _] -> " Did you mean #{inspect(top)}?"
        [] -> ""
      end

    {"#{inspect(receiver)} does not understand #{inspect(selector)}/#{arity}." <> hint,
     {:does_not_understand, receiver, selector, arity, suggestions}}
  end

  defp failure_cause([{:constraint_violated, violation} | _], _ancestry, _failed_on, _state) do
    {constraint_violation_message(violation), {:constraint_violated, pretty_violation(violation)}}
  end

  defp failure_cause([{:domain_violated, resolved, values} | _], _ancestry, _failed_on, _state) do
    {"#{inspect(resolved)} is not in the domain #{inspect(values)}.",
     {:domain_violated, resolved, values}}
  end

  # Every native diagnostic below is a tagged 2-tuple ({:tag, payload})
  # rather than a flat N-tuple -- the DNU clause above pattern-matches
  # an *untyped* 4-tuple ({receiver, selector, arity, suggestions}), so
  # any native diagnostic shaped as a bare 4-tuple would silently and
  # incorrectly match it first regardless of its actual tag.
  defp failure_cause(
         [{:native_missing, {method_id, {module, function, arity, _style}}} | _],
         _ancestry,
         _failed_on,
         state
       ) do
    label = native_label(method_id, state.branch)

    {"method #{label} is declared native (#{inspect(module)}.#{function}/#{arity}) " <>
       "but that implementation is not registered in this image.",
     {:native_missing, method_id, {module, function, arity}}}
  end

  defp failure_cause(
         [
           {:native_mismatch,
            {method_id, {expected_module, expected_fun, expected_arity, _},
             {actual_module, actual_fun, actual_arity, _}}}
           | _
         ],
         _ancestry,
         _failed_on,
         state
       ) do
    label = native_label(method_id, state.branch)

    {"method #{label} is declared native backed by " <>
       "#{inspect(expected_module)}.#{expected_fun}/#{expected_arity}, but this image " <>
       "has #{inspect(actual_module)}.#{actual_fun}/#{actual_arity} registered instead.",
     {:native_mismatch, method_id, {expected_module, expected_fun, expected_arity},
      {actual_module, actual_fun, actual_arity}}}
  end

  defp failure_cause(
         [{:native_input_not_ground, {method_id, position}} | _],
         _ancestry,
         _failed_on,
         state
       ) do
    label = native_label(method_id, state.branch)

    {"native method #{label} needs input ##{position} to be ground, but it's " <>
       "still an open variable.", {:native_input_not_ground, method_id, position}}
  end

  defp failure_cause(
         [{:native_error, {method_id, {module, function}, exception_message}} | _],
         _ancestry,
         _failed_on,
         state
       ) do
    label = native_label(method_id, state.branch)

    {"native method #{label} (#{inspect(module)}.#{function}) raised: " <> exception_message,
     {:native_error, method_id, {module, function}, exception_message}}
  end

  defp failure_cause([{:label_unconstrained, v} | _], _ancestry, _failed_on, _state) do
    pretty = AL.Trace.pretty(v)

    {"label(#{AL.Syntax.Printer.term(pretty)}) has nothing to enumerate: no finite bounds, domain, or class.",
     {:label_unconstrained, pretty}}
  end

  defp failure_cause([{:unify_failed, a, b} | _], _ancestry, _failed_on, _state) do
    {"#{inspect(a)} and #{inspect(b)} can't be the same.", {:unify_failed, a, b}}
  end

  defp failure_cause([], ancestry, failed_on, state) do
    state.trace.events
    |> root_cause_call(ancestry)
    |> failure_from_call(failed_on)
  end

  defp failure_from_call({:method_call, _scope, self, method, args, _}, _failed_on) do
    {"Goal failed: #{format_call(self, method, args)} had no matching clause.",
     {:goal_failed, {:method_call, AL.Trace.pretty(self), method, AL.Trace.pretty(args)}}}
  end

  defp failure_from_call({:clause_call, _scope, method_id, call_args, _}, _failed_on) do
    {"Goal failed: #{inspect(method_id)}#{inspect(AL.Trace.pretty(call_args))} didn't match.",
     {:goal_failed, {:clause_call, method_id, AL.Trace.pretty(call_args)}}}
  end

  defp failure_from_call(nil, failed_on),
    do: {"Goal failed: #{inspect(failed_on)}", {:goal_failed, failed_on}}

  defp current_failure(state) do
    case state.failure_candidate do
      {_score, {:call, failure}} ->
        AL.Trace.pretty(failure)

      _ ->
        nil
    end
  end

  defp format_call(self, method, args) do
    args_str = args |> AL.Trace.pretty() |> Enum.map(&inspect/1) |> Enum.join(", ")
    "#{inspect(AL.Trace.pretty(self))}.#{method}(#{args_str})"
  end

  # Reverse-looks-up a method_id's own {class, selector} for a readable
  # native-diagnostic label -- falls back to the bare method_id if none is
  # found (e.g. a fork that never installed the class this native targets).
  defp native_label(method_id, branch) do
    case AL.Object.scan_method(
           {:"$var", "native_label_self"},
           {:"$var", "native_label_name"},
           method_id,
           branch
         ) do
      [{:method, class, name, ^method_id} | _] -> "#{inspect(class)}##{name}"
      [] -> inspect(method_id)
    end
  end

  # Only consider events on the actual failing lineage -- siblings tried
  # and abandoned during backtracking would otherwise get blamed just for
  # being nearby in time (see [[al-legible-failures-reporting-gap]]).
  defp root_cause_call(raw_trace, ancestry) do
    chronological =
      raw_trace
      |> Enum.reverse()
      |> AL.Trace.payloads()
      |> Enum.filter(&MapSet.member?(ancestry, event_scope(&1)))

    case Enum.find(chronological, &fail_event?/1) do
      nil -> nil
      {_tag, scope} -> Enum.find(chronological, &call_event_for?(&1, scope))
    end
  end

  defp fail_event?({tag, _scope}) when tag in [:method_fail, :clause_fail], do: true
  defp fail_event?(_), do: false

  defp call_event_for?({:method_call, scope, _self, _method, _args, _}, scope), do: true
  defp call_event_for?({:clause_call, scope, _method_id, _call_args, _}, scope), do: true
  defp call_event_for?(_, _), do: false

  # Every Domino payload tuple carries its own scope as the 2nd element,
  # regardless of arity -- raw goals (full trace) and control markers
  # (:backtrack) aren't domino events and have no scope of their own.
  defp event_scope({_tag, scope}), do: scope
  defp event_scope({_tag, scope, _}), do: scope
  defp event_scope({_tag, scope, _, _}), do: scope
  defp event_scope({_tag, scope, _, _, _}), do: scope
  defp event_scope({_tag, scope, _, _, _, _}), do: scope
  defp event_scope(_), do: nil

  # `trace.runtime.scopes` deliberately deletes a scope's bookkeeping the moment
  # it fails, to keep a long backtracking search's live state bounded (see
  # `AL.JAM.Trace.fail/2`), and `AL.Trace.derivation_tree/1` does the same thing
  # for the same reason (it's built to show the *successful* path) -- so
  # neither can answer "what actually failed." The retained event journal is
  # never pruned, so the lineage gets reconstructed from it directly: AL
  # tries alternatives in call order, so at any given parent scope, the
  # child that was opened *last* is the one that was never superseded by
  # a later sibling -- walking that "last child" chain from the root down
  # to a leaf lands on the actual final call that failed, using nothing
  # but data already in the trace, no machine-level marking needed.
  defp failing_lineage(raw_trace) do
    chronological = raw_trace |> Enum.reverse() |> AL.Trace.payloads()

    {_stack, parents, opens} =
      Enum.reduce(chronological, {[], %{}, []}, fn
        {tag, scope, _, _, _, _}, {stack, parents, opens} when tag == :method_call ->
          parent = List.first(stack, 0)
          {[scope | stack], Map.put(parents, scope, parent), [{scope, parent} | opens]}

        {tag, scope, _, _, _}, {stack, parents, opens} when tag == :clause_call ->
          parent = List.first(stack, 0)
          {[scope | stack], Map.put(parents, scope, parent), [{scope, parent} | opens]}

        {tag, _scope, _}, {[_ | rest], parents, opens}
        when tag in [:method_exit, :clause_exit] ->
          {rest, parents, opens}

        {tag, _scope}, {[_ | rest], parents, opens} when tag in [:method_fail, :clause_fail] ->
          {rest, parents, opens}

        {tag, scope}, {stack, parents, opens} when tag in [:method_redo, :clause_redo] ->
          {[scope | stack], parents, opens}

        _other, acc ->
          acc
      end)

    opens = Enum.reverse(opens)
    leaf = walk_last_child(opens, 0)
    scope_ancestry(parents, leaf)
  end

  defp walk_last_child(opens, scope) do
    case last_child(opens, scope) do
      nil -> scope
      child -> walk_last_child(opens, child)
    end
  end

  defp last_child(opens, parent) do
    case Enum.filter(opens, fn {_scope, p} -> p == parent end) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  defp scope_ancestry(parents, scope) do
    scope
    |> Stream.iterate(&Map.get(parents, &1))
    |> Enum.take_while(&(&1 != nil))
    |> MapSet.new()
  end

  # trace is prepended (most-recent-first) — tail is already at the head, no
  # need to touch the rest. count*5 pads against interspersed :backtrack markers.
  defp last_raw_steps(trace, count) do
    trace
    |> Enum.take(count * 5)
    |> Enum.reject(&(AL.Trace.payload(&1) == :backtrack))
    |> Enum.take(count)
    |> Enum.reverse()
  end

  defp constraint_violation_message({:dif, a, b}) do
    "Constraint violated: dif(#{inspect(AL.Trace.pretty(a))}, #{inspect(AL.Trace.pretty(b))}) " <>
      "required these to stay different."
  end

  defp constraint_violation_message({:isa, var, class}) do
    "Constraint violated: #{inspect(AL.Trace.pretty(var))} was required to resolve within " <>
      "class #{inspect(class)}."
  end

  defp constraint_violation_message({:class, var, class}) do
    "Constraint violated: #{inspect(AL.Trace.pretty(var))} was required to have direct class " <>
      "#{inspect(class)}."
  end

  defp constraint_violation_message({:bounds, {lo, hi}}) do
    "Constraint violated: value was required to stay within bounds [#{inspect(lo)}, #{inspect(hi)}]."
  end

  defp constraint_violation_message({:domain, domain}) do
    "Constraint violated: value was required to be one of #{inspect(MapSet.to_list(domain))}."
  end

  defp pretty_violation({:dif, a, b}), do: {:dif, AL.Trace.pretty(a), AL.Trace.pretty(b)}
  defp pretty_violation({:class, var, class}), do: {:class, AL.Trace.pretty(var), class}
  defp pretty_violation({:isa, var, class}), do: {:isa, AL.Trace.pretty(var), class}
  defp pretty_violation({:bounds, bounds}), do: {:bounds, bounds}
  defp pretty_violation({:domain, domain}), do: {:domain, MapSet.to_list(domain)}
end
