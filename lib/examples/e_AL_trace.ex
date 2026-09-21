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
        run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
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
        run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
          member([:a, :b], :z)
        end
      end)

    AL.notrace()

    assert String.contains?(output, "Call:")
    assert String.contains?(output, "Fail:")
    output
  end

  # Domino tracing model: two stacked Byrd boxes (method dispatch wraps
  # clause selection), each with its own Call/Exit/Redo/Fail. `fibonacci` is
  # entirely ground dispatch (self is always a concrete number), so it only
  # ever needs one provider -- exercises the *clause* level (multiple
  # clauses of the one chosen method_id: [1,1], [2,1], [n,x]) without any
  # method-level backtracking, and method_exit still fires by propagation
  # (mark_exited/2, AL.ex) once the top-level fibonacci(3, x) call's own
  # clause exits, even though dispatch never had its own return address.
  example fibonacci_trace_shows_clause_level_ports() do
    {:atomic, {bindings, _constraints, state}} =
      run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
        fibonacci(3, x)
      end

    assert Map.get(bindings, :"$x") == 2

    kinds =
      state.trace.events
      |> AL.Trace.payloads()
      |> Enum.map(fn
        entry when is_tuple(entry) -> elem(entry, 0)
        entry -> entry
      end)

    assert :method_call in kinds
    assert :method_exit in kinds
    assert :clause_call in kinds
    assert :clause_exit in kinds
  end

  # Call/Exit are self-contained: Call names what was already known about
  # an open position walking in (here, nothing -- x2 is freshly minted,
  # `{:open, %{}}`), Exit names what got derived walking out, resolved
  # against *that scope's own* store, not the run's final one. No need to
  # go hunt down the matching Call event to know which var to look up.
  example fibonacci_base_case_derives_a_bound_value_at_its_own_exit() do
    {:atomic, {_bindings, _constraints, state}} =
      run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
        fibonacci(3, x)
      end

    chronological = state.trace.events |> Enum.reverse() |> AL.Trace.payloads()

    {:method_call, _scope, 1, :fibonacci, [x2], constraints_in} =
      Enum.find(chronological, &match?({:method_call, _, 1, :fibonacci, _, _}, &1))

    assert constraints_in == %{x2 => {:open, %{}}}

    {:method_exit, _scope, derived} =
      Enum.find(chronological, &match?({:method_exit, _, %{^x2 => _}}, &1))

    assert derived == %{x2 => {:bound, 1}}
  end

  example dispatch_trace_closes_the_failed_method() do
    {:atomic, _} =
      run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
        defclass :redo_probe_class, super: :value, ivars: [] do
          defmethod(:redo_probe, [self, :from_a])
        end
      end

    {:aborted, reason} =
      run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
        redo_probe(x, tag)
        tag = :not_a
      end

    kinds =
      reason.trace
      |> AL.Trace.payloads()
      |> Enum.map(fn
        entry when is_tuple(entry) -> elem(entry, 0)
        entry -> entry
      end)

    refute :clause_redo in kinds
    assert :method_fail in kinds
  end

  # `:derivation_trace` carries domino events and constraints, without raw
  # goals. `:full_trace` additionally interleaves each raw goal plus
  # `:backtrack`/`:flounder`
  # into that *same* list, in true chronological order alongside the
  # domino events -- not a second field to cross-reference, so
  # AL.Trace.render/1 can print both together with correct nesting from a
  # single forward walk.
  example full_trace_interleaves_raw_goals_into_trace() do
    {:atomic, {_bindings, _constraints, plain_state}} =
      run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
        fibonacci(3, x)
      end

    refute Enum.any?(plain_state.trace.events, fn event ->
             match?(%AL.Goal.Send{}, AL.Trace.payload(event))
           end)

    assert plain_state.trace.flags == MapSet.new([:domino])

    {:atomic, {_bindings, _constraints, traced_state}} =
      run branch: Examples.Support.branch(), trace_mode: :full_trace do
        fibonacci(3, x)
      end

    assert Enum.any?(traced_state.trace.events, fn event ->
             match?(%AL.Goal.Send{}, AL.Trace.payload(event))
           end)

    assert Enum.any?(traced_state.trace.events, fn event ->
             match?({:method_call, _, _, _, _, _}, AL.Trace.payload(event))
           end)

    assert traced_state.trace.flags == MapSet.new([:domino, :vm])

    output =
      capture_io(fn ->
        traced_state.trace.events
        |> Enum.reverse()
        |> Enum.map(&AL.Trace.pretty/1)
        |> AL.Trace.render()
      end)

    assert String.contains?(output, "Method Call:")
    assert String.contains?(output, "Send")
  end

  example composable_trace_flags_select_independent_event_families() do
    {:atomic, {_bindings, _constraints, domino_state}} =
      run branch: Examples.Support.branch(), trace: [:domino] do
        fibonacci(3, x)
      end

    assert domino_state.trace.flags == MapSet.new([:domino])
    assert Enum.any?(domino_state.trace.events, &match?(%AL.Trace.Event{kind: :domino}, &1))
    assert Enum.all?(domino_state.trace.events, &match?(%AL.Trace.Event{kind: :domino}, &1))

    {:atomic, {_bindings, _constraints, vm_state}} =
      run branch: Examples.Support.branch(), trace: [:vm] do
        pass()
      end

    assert vm_state.trace.flags == MapSet.new([:vm])

    assert Enum.any?(vm_state.trace.events, fn event ->
             match?(%AL.Trace.Event{kind: :vm, payload: %AL.Goal.Pass{}}, event)
           end)

    refute Enum.any?(vm_state.trace.events, &match?(%AL.Trace.Event{kind: :domino}, &1))
  end

  example trace_flags_compose_without_duplicate_constraint_events() do
    {:atomic, {_bindings, _constraints, state}} =
      run branch: Examples.Support.branch(), trace: [:domino, :vm] do
        x = y + 1
        y = 4
      end

    arithmetic_events =
      Enum.filter(
        state.trace.events,
        &match?(
          %AL.Trace.Event{
            kind: :domino,
            payload: {:constraint, %AL.Goal.Eq{b: %AL.Goal.OApply{}}, _, _}
          },
          &1
        )
      )

    assert length(arithmetic_events) == 1
  end

  example findall_merges_its_nested_evaluation_trace() do
    {:atomic, {bindings, _constraints, state}} =
      run branch: Examples.Support.branch(), trace: [:domino, :vm] do
        findall(x, xs) do
          member([1, 2], x)
        end
      end

    assert Map.get(bindings, :"$xs") == [1, 2]

    chronological = state.trace.events |> Enum.reverse() |> AL.Trace.payloads()
    assert Enum.any?(chronological, &match?(%AL.Goal.Findall{}, &1))
    assert Enum.any?(chronological, &match?(%AL.Goal.Send{method: :member}, &1))
    assert Enum.any?(chronological, &match?({:method_call, _, _, :member, _, _}, &1))

    findall_index = Enum.find_index(chronological, &match?(%AL.Goal.Findall{}, &1))

    member_index = Enum.find_index(chronological, &match?(%AL.Goal.Send{method: :member}, &1))

    assert findall_index < member_index
  end

  example findall_derivation_tree_keeps_each_successful_nested_proof() do
    {:atomic, {bindings, _constraints, state}} =
      run branch: Examples.Support.branch(), trace: [:domino, :vm] do
        findall(x, xs) do
          member([1, 2], x)
        end
      end

    assert Map.get(bindings, :"$xs") == [1, 2]

    [collection] = AL.Trace.derivation_tree(state)
    assert collection.kind == :collection
    assert [findall_answer] = collection.children
    assert Map.fetch!(findall_answer.derived, :"$xs") == {:bound, [1, 2]}

    member = Enum.find(findall_answer.children, &match?(%{label: {_, :member, _}}, &1))
    answers = Enum.map(member.children, &Map.fetch!(&1.derived, :"$x"))

    assert answers == [{:bound, 1}, {:bound, 2}]
  end

  example findall_derivation_tree_keeps_constraint_transitions_separate_from_solutions() do
    {:atomic, {bindings, _constraints, state}} =
      run branch: Examples.Support.branch(), trace: [:domino] do
        findall(x, xs) do
          x > 0
          x < 3
          label(x)
        end
      end

    assert Map.get(bindings, :"$xs") == [1, 2]

    [collection] = AL.Trace.derivation_tree(state)
    assert [findall_answer] = collection.children
    assert Map.fetch!(findall_answer.derived, :"$xs") == {:bound, [1, 2]}

    nodes = derivation_nodes(findall_answer)
    lower = Enum.find(nodes, &match?(%{label: %AL.Goal.Compare{op: :>}}, &1))
    upper = Enum.find(nodes, &match?(%{label: %AL.Goal.Compare{op: :<}}, &1))

    assert Map.fetch!(lower.constraints_in, :"$x") == {:open, %{}}
    assert Map.fetch!(lower.derived, :"$x") == {:open, %{bounds: {1, nil}}}
    assert Map.fetch!(upper.constraints_in, :"$x") == {:open, %{bounds: {1, nil}}}
    assert Map.fetch!(upper.derived, :"$x") == {:open, %{bounds: {1, 2}}}

    assert labeled_values(findall_answer) == [1, 2]
  end

  example findall_derivation_tree_retains_min_by_proofs_and_answer_constraints() do
    {:atomic, {bindings, _constraints, state}} =
      run branch: Examples.Support.branch(), trace: [:domino, :vm] do
        findall([m, x], xs) do
          x > 0
          x < 11
          min_by([[3, 5], [4, 7], [5, 3], [x, 7]], :hd, m)
          label(x)
        end
      end

    assert length(Map.fetch!(bindings, :"$xs")) == 11

    nodes = state |> AL.Trace.derivation_tree() |> derivation_nodes()
    min_by = Enum.find(nodes, &match?(%{label: {_, :min_by, _}}, &1))
    assert length(min_by.children) == 2

    label_answers = Enum.map(min_by.children, &labeled_values/1)

    assert label_answers == [
             Enum.to_list(3..10),
             Enum.to_list(1..3)
           ]

    lower_bounds =
      nodes
      |> Enum.filter(&match?(%{label: %AL.Goal.Compare{a: :"$x", op: :>}}, &1))
      |> Enum.map(&Map.fetch!(&1.derived, :"$x"))

    assert lower_bounds == [{:open, %{bounds: {1, nil}}}]
  end

  example derivation_tree_prunes_rejected_min_by_answers() do
    {:atomic, {_bindings, _constraints, state}} =
      run branch: Examples.Support.branch(), trace: [:domino] do
        findall([m, x], xs) do
          x > 0
          x < 11
          min_by([[3, 5], [4, 7], [5, 3], [x, 7]], :hd, m)
        end
      end

    [collection] = AL.Trace.derivation_tree(state)
    assert [findall_answer] = collection.children

    lower =
      Enum.find(findall_answer.children, &match?(%{label: %AL.Goal.Compare{op: :>}}, &1))

    upper =
      Enum.find(findall_answer.children, &match?(%{label: %AL.Goal.Compare{op: :<}}, &1))

    assert Map.fetch!(lower.constraints_in, :"$x") == {:open, %{}}
    assert Map.fetch!(lower.derived, :"$x") == {:open, %{bounds: {1, nil}}}
    assert Map.fetch!(upper.constraints_in, :"$x") == {:open, %{bounds: {1, nil}}}
    assert Map.fetch!(upper.derived, :"$x") == {:open, %{bounds: {1, 10}}}

    min_by = Enum.find(findall_answer.children, &match?(%{label: {_, :min_by, _}}, &1))
    assert Enum.all?(min_by.children, &match?(%{kind: :answer, clause: 0}, &1))

    method_derivations = Enum.map(min_by.children, &Map.fetch!(&1.derived, :"$x"))

    assert method_derivations == [
             {:open, %{bounds: {3, 10}}},
             {:open, %{bounds: {1, 3}}}
           ]

    rejected =
      collection
      |> derivation_nodes()
      |> Enum.filter(fn
        %{label: %AL.Goal.Compare{op: :<=, a: a, b: 3}} when a in [4, 5] -> true
        _ -> false
      end)

    assert rejected == []
  end

  defp derivation_nodes(nodes) when is_list(nodes),
    do: Enum.flat_map(nodes, &derivation_nodes/1)

  defp derivation_nodes(node), do: [node | derivation_nodes(node.children)]

  defp labeled_values(node) do
    label =
      node
      |> derivation_nodes()
      |> Enum.filter(&match?(%{label: {_, :between, _}}, &1))
      |> Enum.max_by(&length(&1.children))

    Enum.map(label.children, fn answer ->
      answer.derived
      |> Map.values()
      |> Enum.find_value(fn
        {:bound, value} when is_integer(value) -> value
        _description -> nil
      end)
    end)
  end

  example no_trace_is_the_default_and_retains_no_execution_history() do
    {:atomic, {_bindings, _constraints, state}} =
      run branch: Examples.Support.branch() do
        fibonacci(3, x)
      end

    assert state.trace.flags == MapSet.new()
    assert state.trace.events == []
    assert state.trace.runtime.scopes == %{}
    assert state.active_choicepoint.failure_context == []
  end

  example no_trace_still_honours_live_tracepoints_without_retaining_them() do
    ref = make_ref()
    AL.trace(:fibonacci)

    output =
      try do
        capture_io(fn ->
          {:atomic, {_bindings, _constraints, state}} =
            run branch: Examples.Support.branch(), trace_mode: :no_trace do
              fibonacci(3, x)
            end

          send(self(), {ref, state})
        end)
      after
        AL.notrace()
      end

    assert_receive {^ref, state}
    assert String.contains?(output, "Method Call:")
    assert state.trace.events == []
    assert state.trace.runtime.scopes == %{}
    assert state.trace.runtime.traced_calls == %{}
  end

  example trace_mode_rejects_unknown_values() do
    assert_raise ArgumentError, ~r/trace_mode must be/, fn ->
      run branch: Examples.Support.branch(), trace_mode: :unknown do
        pass()
      end
    end
  end

  example trace_flags_reject_unknown_values_and_conflicting_legacy_mode() do
    assert_raise ArgumentError, ~r/unknown trace flags/, fn ->
      run branch: Examples.Support.branch(), trace: [:unknown] do
        pass()
      end
    end

    assert_raise ArgumentError, ~r/cannot be used together/, fn ->
      AL.eval(
        [%AL.Goal.Pass{}],
        nil,
        Examples.Support.branch(),
        trace: [:vm],
        trace_mode: :full_trace
      )
    end
  end

  # `AL.Trace.derivation_tree/1` is the complementary view to `render/1`:
  # only the surviving derivation, as real nested nodes, not just indented
  # text. fibonacci(3, x)'s two recursive calls are both plain ground
  # dispatch (self already concrete by the time the recursive send fires),
  # so each method-box collapses cleanly into its clause-box -- one node
  # per `fibonacci` call, not two.
  example fibonacci_derivation_tree_collapses_and_nests() do
    {:atomic, {_bindings, _constraints, state}} =
      run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
        fibonacci(3, x)
      end

    [root] = AL.Trace.derivation_tree(state)

    assert root.kind == :method
    assert {3, :fibonacci, _args} = root.label
    [answer] = root.children
    assert [{_var, {:bound, 2}}] = Map.to_list(answer.derived)

    method_children = Enum.filter(answer.children, &(&1.kind == :method))
    assert length(method_children) == 2

    selves = Enum.map(method_children, fn %{label: {self, :fibonacci, _}} -> self end)
    assert Enum.sort(selves) == [1, 2]

    assert Enum.all?(method_children, fn child ->
             match?([%{kind: :answer, children: []}], child.children)
           end)
  end

  # Backward search: self starts open, so this goes through the generative
  # candidate leg (construct a :number, then match fibonacci's own clauses
  # against it) rather than plain ground dispatch. A single root -- not one
  # per candidate attempt -- proves the candidate's construction sends and
  # its eventual clause match both nest correctly under the one send that
  # opened them, with the final bound answer on the root itself.
  example fibonacci_backward_search_derivation_tree_is_one_root() do
    {:atomic, {bindings, _constraints, state}} =
      run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
        fibonacci(x, 8)
      end

    assert Map.get(bindings, :"$x") == 6

    [root] = AL.Trace.derivation_tree(state)

    assert root.kind == :method
    assert {_self, :fibonacci, _args} = root.label
    assert [%{derived: derived}] = root.children
    assert [{_var, {:bound, 6}}] = Map.to_list(derived)

    assert all_nodes_derived?(root)
  end

  defp all_nodes_derived?(%{kind: :answer, derived: nil}), do: false
  defp all_nodes_derived?(node), do: Enum.all?(node.children, &all_nodes_derived?/1)

  example fibonacci_deep_backward_search_survives_fail_after_exit() do
    {:atomic, {bindings, _constraints, state}} =
      run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
        fibonacci(x, 21)
      end

    assert Map.get(bindings, :"$x") == 8

    roots = AL.Trace.derivation_tree(state)
    assert length(roots) == 1

    [root] = roots
    assert all_nodes_derived?(root)

    values = AL.Trace.method_values(roots, :fibonacci) |> Enum.sort()

    assert values == [
             {1, [1]},
             {2, [1]},
             {3, [2]},
             {4, [3]},
             {5, [5]},
             {6, [8]},
             {7, [13]},
             {8, [21]}
           ]
  end

  # AL.Trace.method_values/2 doesn't care which position was open at call
  # time -- it just resolves self/args through each node's own `derived`, so
  # the same call against a forward-search tree (self ground) and a
  # backward-search tree (self open) both surface the identical intermediate
  # Fibonacci sequence up to their own target.
  example method_values_reads_intermediate_calls_either_direction() do
    {:atomic, {_bindings, _constraints, forward_state}} =
      run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
        fibonacci(3, x)
      end

    {:atomic, {_bindings, _constraints, backward_state}} =
      run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
        fibonacci(x, 8)
      end

    forward_roots = AL.Trace.derivation_tree(forward_state)
    backward_roots = AL.Trace.derivation_tree(backward_state)

    forward_values = AL.Trace.method_values(forward_roots, :fibonacci) |> Enum.sort()
    backward_values = AL.Trace.method_values(backward_roots, :fibonacci) |> Enum.sort()

    assert forward_values == [{1, [1]}, {2, [1]}, {3, [2]}]
    assert backward_values == [{1, [1]}, {2, [1]}, {3, [2]}, {4, [3]}, {5, [5]}, {6, [8]}]
  end

  # Redo-reset: `pick`'s two clauses both structurally match a durable
  # instance (unlike fibonacci's self-selecting heads) -- the first exits
  # with :first, `result = :second` rejects it, backtracking redoes the
  # SAME clause scope into the second clause, which exits with :second.
  # The tree shows exactly one `pick` node carrying the winning (second)
  # derived value, not the abandoned first one -- proof tree_step's redo
  # handling (reset children, keep the node) is correct, not just Call/Exit.
  example derivation_tree_keeps_only_the_winning_redo_attempt() do
    {:atomic, _} =
      run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
        defclass :redo_demo, super: :object, ivars: [] do
        end

        defmethod(:redo_demo, :pick, [self, :first])
        defmethod(:redo_demo, :pick, [self, :second])
      end

    {:atomic, {bindings, _constraints, state}} =
      run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
        new(:redo_demo, %{}, obj)
        pick(obj, result)
        result = :second
      end

    assert Map.get(bindings, :"$result") == :second

    roots = AL.Trace.derivation_tree(state)
    pick_node = Enum.find(roots, &match?(%{label: {_, :pick, _}}, &1))

    assert [%{clause: 1, children: [], derived: derived}] = pick_node.children
    assert [{_var, {:bound, :second}}] = Map.to_list(derived)
  end

  example free_ask_keeps_every_call_under_the_frame_that_made_it() do
    {:atomic, _} =
      run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
        defclass :chain_box, super: :object, ivars: [] do
          defmethod(:chain, [self, 1, 1])
          defmethod(:chain, [self, 2, 1])

          defmethod(:chain, [self, n, v]) do
            n > 2
            n1 = n - 1
            n2 = n - 2
            chain(self, n1, v1)
            chain(self, n2, v2)
            v = v1 + v2
          end
        end
      end

    {:atomic, {bindings, _constraints, state}} =
      run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
        new(:chain_box, %{}, obj)
        chain(obj, n, 21)
      end

    assert Map.get(bindings, :"$n") == 8

    frames =
      AL.Trace.derivation_tree(state)
      |> Enum.flat_map(&chain_frames/1)

    assert Enum.reject(frames, fn {n, calls} -> calls == predecessors(n) end) == []

    frames
  end

  defp predecessors(n) when n > 2, do: [n - 1, n - 2]
  defp predecessors(_n), do: []

  # Every `chain` node, as {n it was called on, n of each `chain` call it made}.
  defp chain_frames(%{label: {_, :chain, _}} = node) do
    [answer] = node.children
    calls = Enum.filter(answer.children, &match?(%{label: {_, :chain, _}}, &1))
    [{chain_arg(node), Enum.map(calls, &chain_arg/1)} | descend(node)]
  end

  defp chain_frames(node), do: descend(node)

  defp descend(node), do: Enum.flat_map(node.children, &chain_frames/1)

  defp chain_arg(%{label: {_, :chain, [n | _]}, children: [%{derived: derived}]}) do
    case derived && Map.get(derived, n) do
      {:bound, value} -> value
      _ -> n
    end
  end

  example call_node_names_the_clause_that_fired() do
    {:atomic, _} =
      run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
        defclass :pick_box, super: :object, ivars: [] do
          defmethod(:pick, [self, :first])
          defmethod(:pick, [self, :second])
          defmethod(:pick, [self, :third])
        end
      end

    {:atomic, {bindings, _constraints, state}} =
      run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
        new(:pick_box, %{}, obj)
        pick(obj, chosen)
        chosen = :third
      end

    assert Map.get(bindings, :"$chosen") == :third

    roots = AL.Trace.derivation_tree(state)
    pick_node = Enum.find(roots, &match?(%{label: {_, :pick, _}}, &1))

    assert [%{clause: 2}] = pick_node.children
    pick_node
  end

  example node_names_the_committed_clause_not_the_one_abandoned_mid_body() do
    {:atomic, _} =
      run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
        defclass :attempt_box, super: :object, ivars: [] do
          defmethod(:probe, [self, 1])

          defmethod(:try, [self, v]) do
            probe(self, w)
            w = 99
            v = :unreachable
          end

          defmethod(:try, [self, :committed])
        end
      end

    {:atomic, {bindings, _constraints, state}} =
      run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
        new(:attempt_box, %{}, obj)
        try(obj, answer)
      end

    assert Map.get(bindings, :"$answer") == :committed

    roots = AL.Trace.derivation_tree(state)
    try_node = Enum.find(roots, &match?(%{label: {_, :try, _}}, &1))

    assert [%{clause: 1}] = try_node.children
    try_node
  end

  example derivation_tree_keeps_the_committed_chain_after_a_failed_attempt() do
    {:atomic, _} =
      run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
        defclass :probe_box, super: :object, ivars: [] do
          defmethod(:probe_reject, [self, v]) do
            v = 1
            v > 50
          end

          defmethod(:probe_leaf, [self, 100])

          defmethod(:probe_mid, [self, v]) do
            probe_leaf(self, w)
            v = w + 1
          end

          defmethod(:probe_top, [self, v]) do
            probe_mid(self, w)
            v = w + 1
          end

          defmethod(:probe_answer, [self, v]) do
            alternative([probe_reject(self, v)], [probe_top(self, v)])
          end
        end
      end

    {:atomic, {bindings, _constraints, state}} =
      run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
        new(:probe_box, %{}, obj)
        probe_answer(obj, r)
      end

    assert Map.get(bindings, :"$r") == 102

    roots = AL.Trace.derivation_tree(state)
    answer = Enum.find(roots, &match?(%{label: {_, :probe_answer, _}}, &1))

    assert [%{children: [top]}] = answer.children
    assert {_, :probe_top, _} = top.label

    assert [%{children: top_steps}] = top.children
    assert [mid] = Enum.filter(top_steps, &(&1.kind == :method))
    assert {_, :probe_mid, _} = mid.label

    assert [%{children: mid_steps}] = mid.children
    assert [leaf] = Enum.filter(mid_steps, &(&1.kind == :method))
    assert {_, :probe_leaf, _} = leaf.label

    refute Enum.any?(roots, &match?(%{label: {_, :probe_reject, _}}, &1))
  end

  # Call/Fail only fires once a clause applies -- says nothing about which
  # candidate legs an unbound receiver tried. Selector trace shows legs before
  # any run. durable reports "deferred" not a count -- scanning to report one
  # would force the lazy scan it's meant to avoid.
  example trace_shows_dispatch_legs() do
    {:atomic, _} =
      run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
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
        run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
          trace_next(x, %{class: :trace_leg_class, letter: :b})
        end
      end)

    AL.notrace()

    assert String.contains?(output, "Dispatch: ")
    assert String.contains?(output, "providers=[:trace_leg_class]")
  end

  example constraint_goals_are_retained_in_derivation_mode() do
    {:atomic, {_bindings, _constraints, state}} =
      run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
        x = 5
        y = x + 1
        dif(x, z)
        all_dif([x, z, w])
        in_domain(w, [1, 2, 3])
      end

    constraints =
      state.trace.events
      |> AL.Trace.payloads()
      |> Enum.flat_map(fn
        {:constraint, goal, _constraints_in, _derived} -> [goal]
        _event -> []
      end)

    assert Enum.any?(constraints, &match?(%AL.Goal.Eq{b: %AL.Goal.OApply{}}, &1))
    assert Enum.any?(constraints, &match?(%AL.Goal.Dif{}, &1))
    assert Enum.any?(constraints, &match?(%AL.Goal.AllDif{}, &1))
    assert Enum.any?(constraints, &match?(%AL.Goal.InDomain{}, &1))
    refute Enum.any?(constraints, &match?(%AL.Goal.Eq{b: 5}, &1))
  end

  example derivation_tree_includes_constraint_nodes_with_resolved_values() do
    {:atomic, {bindings, _constraints, state}} =
      run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
        y = 5
        x = y * 3
      end

    assert Map.get(bindings, :"$x") == 15

    roots = AL.Trace.derivation_tree(state)

    [constraint_node] = roots
    assert constraint_node.kind == :constraint
    assert %AL.Goal.Eq{b: %AL.Goal.OApply{method_id: :*}} = constraint_node.label
    assert Map.get(constraint_node.derived, :"$x") == {:bound, 15}
  end

  example derivation_tree_nests_constraint_goals_under_their_scope() do
    {:atomic, _} =
      run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
        defclass :triple_class, super: :object, ivars: [] do
          defmethod(:triple, [self, n, result]) do
            result = n * 3
          end
        end
      end

    {:atomic, {bindings, _constraints, state}} =
      run branch: Examples.Support.branch(), trace_mode: :derivation_trace do
        new(:triple_class, %{}, obj)
        triple(obj, 4, r)
      end

    assert Map.get(bindings, :"$r") == 12

    roots = AL.Trace.derivation_tree(state)

    root = Enum.find(roots, &match?(%{label: {_, :triple, _}}, &1))
    assert [answer] = root.children
    assert {:open, %{}} in Map.values(root.constraints_in)
    assert {:bound, 12} in Map.values(answer.derived)

    constraint_children = Enum.filter(answer.children, &(&1.kind == :constraint))
    assert length(constraint_children) == 1

    [constraint_node] = constraint_children
    assert {:open, %{}} in Map.values(constraint_node.constraints_in)
    assert {:bound, 12} in Map.values(constraint_node.derived)
  end
end
