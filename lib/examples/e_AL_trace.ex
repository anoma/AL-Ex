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

  # Domino tracing model: two stacked Byrd boxes (method dispatch wraps
  # clause selection), each with its own Call/Exit/Redo/Fail. `fibonacci` is
  # entirely ground dispatch (self is always a concrete number), so it only
  # ever needs one provider -- exercises the *clause* level (multiple
  # clauses of the one chosen method_id: [1,1], [2,1], [n,x]) without any
  # method-level backtracking, and method_exit still fires by propagation
  # (mark_exited/2, AL.ex) once the top-level fibonacci(3, x) call's own
  # clause exits, even though dispatch never had its own return address.
  example fibonacci_trace_shows_clause_level_ports() do
    {:atomic, {bindings, state}} =
      run branch: :examples do
        fibonacci(3, x)
      end

    assert Map.get(bindings, :"$x") == 2

    kinds =
      Enum.map(state.domino.trace, fn
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
    {:atomic, {_bindings, state}} =
      run branch: :examples do
        fibonacci(3, x)
      end

    chronological = Enum.reverse(state.domino.trace)

    {:method_call, _scope, 1, :fibonacci, [x2], constraints_in} =
      Enum.find(chronological, &match?({:method_call, _, 1, :fibonacci, _, _}, &1))

    assert constraints_in == %{x2 => {:open, %{}}}

    {:method_exit, _scope, derived} =
      Enum.find(chronological, &match?({:method_exit, _, %{^x2 => _}}, &1))

    assert derived == %{x2 => {:bound, 1}}
  end

  # A var receiver with exactly one generative candidate class means the
  # *other* candidate every open dispatch always offers -- the durable leg
  # -- is what backtracking reaches next once the generative candidate's
  # own clause (already exited once) turns out not to satisfy the caller.
  # No durable instance of the class exists, so the durable leg finds
  # nothing and the whole send is exhausted: clause_redo (retrying the
  # generative candidate's own clause box) then method_fail (every
  # candidate, generative and durable alike, is exhausted).
  example dispatch_trace_shows_clause_level_redo_and_method_level_fail() do
    {:atomic, _} =
      run branch: :examples do
        defclass :redo_probe_class, super: :value, ivars: [] do
          defmethod(:redo_probe, [self, :from_a])
        end
      end

    {:aborted, reason} =
      run branch: :examples do
        redo_probe(x, tag)
        eq(tag, :not_a)
      end

    kinds =
      Enum.map(reason.trace, fn
        entry when is_tuple(entry) -> elem(entry, 0)
        entry -> entry
      end)

    assert :clause_redo in kinds
    assert :method_fail in kinds
  end

  # `.trace` always carries the domino events (cheap, on by default -- a
  # plain run's trace is domino tuples only, no raw goals). `vm_trace: true`
  # additionally interleaves each raw goal plus `:backtrack`/`:flounder`
  # into that *same* list, in true chronological order alongside the
  # domino events -- not a second field to cross-reference, so
  # AL.Trace.render/1 can print both together with correct nesting from a
  # single forward walk.
  example vm_trace_opt_in_interleaves_raw_goals_into_trace() do
    {:atomic, {_bindings, plain_state}} =
      run branch: :examples do
        fibonacci(3, x)
      end

    refute Enum.any?(plain_state.domino.trace, &match?(%AL.Goal.Send{}, &1))

    {:atomic, {_bindings, traced_state}} =
      run branch: :examples, vm_trace: true do
        fibonacci(3, x)
      end

    assert Enum.any?(traced_state.domino.trace, &match?(%AL.Goal.Send{}, &1))
    assert Enum.any?(traced_state.domino.trace, &match?({:method_call, _, _, _, _, _}, &1))

    output =
      capture_io(fn ->
        traced_state.domino.trace
        |> Enum.reverse()
        |> Enum.map(&AL.Trace.pretty/1)
        |> AL.Trace.render()
      end)

    assert String.contains?(output, "Method Call:")
    assert String.contains?(output, "Send")
  end

  # `AL.Trace.derivation_tree/1` is the complementary view to `render/1`:
  # only the surviving derivation, as real nested nodes, not just indented
  # text. fibonacci(3, x)'s two recursive calls are both plain ground
  # dispatch (self already concrete by the time the recursive send fires),
  # so each method-box collapses cleanly into its clause-box -- one node
  # per `fibonacci` call, not two.
  example fibonacci_derivation_tree_collapses_and_nests() do
    {:atomic, {_bindings, state}} =
      run branch: :examples do
        fibonacci(3, x)
      end

    [root] = state.domino.trace |> Enum.reverse() |> AL.Trace.derivation_tree()

    assert root.kind == :method
    assert {3, :fibonacci, _args} = root.label
    assert [{_var, {:bound, 2}}] = Map.to_list(root.derived)
    assert length(root.children) == 2

    selves = Enum.map(root.children, fn %{label: {self, :fibonacci, _}} -> self end)
    assert Enum.sort(selves) == [1, 2]
    assert Enum.all?(root.children, &(&1.kind == :method and &1.children == []))
  end

  # Backward search: self starts open, so this goes through the generative
  # candidate leg (construct a :number, then match fibonacci's own clauses
  # against it) rather than plain ground dispatch. A single root -- not one
  # per candidate attempt -- proves the candidate's construction sends and
  # its eventual clause match both nest correctly under the one send that
  # opened them, with the final bound answer on the root itself.
  example fibonacci_backward_search_derivation_tree_is_one_root() do
    {:atomic, {bindings, state}} =
      run branch: :examples do
        fibonacci(x, 8)
      end

    assert Map.get(bindings, :"$x") == 6

    [root] = state.domino.trace |> Enum.reverse() |> AL.Trace.derivation_tree()

    assert root.kind == :method
    assert {_self, :fibonacci, _args} = root.label
    assert [{_var, {:bound, 6}}] = Map.to_list(root.derived)

    assert all_nodes_derived?(root)
  end

  defp all_nodes_derived?(%{derived: nil}), do: false
  defp all_nodes_derived?(node), do: Enum.all?(node.children, &all_nodes_derived?/1)

  example fibonacci_deep_backward_search_survives_fail_after_exit() do
    {:atomic, {bindings, state}} =
      run branch: :examples do
        fibonacci(x, 21)
      end

    assert Map.get(bindings, :"$x") == 8

    roots = state.domino.trace |> Enum.reverse() |> AL.Trace.derivation_tree()
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
    {:atomic, {_bindings, forward_state}} =
      run branch: :examples do
        fibonacci(3, x)
      end

    {:atomic, {_bindings, backward_state}} =
      run branch: :examples do
        fibonacci(x, 8)
      end

    forward_roots = forward_state.domino.trace |> Enum.reverse() |> AL.Trace.derivation_tree()
    backward_roots = backward_state.domino.trace |> Enum.reverse() |> AL.Trace.derivation_tree()

    forward_values = AL.Trace.method_values(forward_roots, :fibonacci) |> Enum.sort()
    backward_values = AL.Trace.method_values(backward_roots, :fibonacci) |> Enum.sort()

    assert forward_values == [{1, [1]}, {2, [1]}, {3, [2]}]
    assert backward_values == [{1, [1]}, {2, [1]}, {3, [2]}, {4, [3]}, {5, [5]}, {6, [8]}]
  end

  # Redo-reset: `pick`'s two clauses both structurally match a durable
  # instance (unlike fibonacci's self-selecting heads) -- the first exits
  # with :first, `unify(result, :second)` rejects it, backtracking redoes the
  # SAME clause scope into the second clause, which exits with :second.
  # The tree shows exactly one `pick` node carrying the winning (second)
  # derived value, not the abandoned first one -- proof tree_step's redo
  # handling (reset children, keep the node) is correct, not just Call/Exit.
  example derivation_tree_keeps_only_the_winning_redo_attempt() do
    {:atomic, _} =
      run branch: :examples do
        defclass :redo_demo, super: :object, ivars: [] do
        end

        defmethod(:redo_demo, :pick, [self, :first])
        defmethod(:redo_demo, :pick, [self, :second])
      end

    {:atomic, {bindings, state}} =
      run branch: :examples do
        new(:redo_demo, %{}, obj)
        pick(obj, result)
        unify(result, :second)
      end

    assert Map.get(bindings, :"$result") == :second

    roots = state.domino.trace |> Enum.reverse() |> AL.Trace.derivation_tree()
    pick_node = Enum.find(roots, &match?(%{label: {_, :pick, _}}, &1))

    assert pick_node.children == []
    assert [{_var, {:bound, :second}}] = Map.to_list(pick_node.derived)
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
end
