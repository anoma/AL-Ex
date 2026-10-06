defmodule AL do
  @moduledoc """
  I run AL transactions

  I define the state of an AL program and drive the abstract machine
  (`AL.JAM`) that executes it: I hold the choicepoints it yields, apply its
  mutations, and commit or abort the transaction
  """
  use TypedStruct
  alias AL.Goal

  @type scope() :: non_neg_integer()
  @type failure_call() ::
          {:method_call, scope(), term(), term(), [term()], %{}}
          | {:clause_call, scope(), term(), term(), %{}}

  # A resolution cursor: Necessary for `call_next_method`

  @type stack_entry() ::
          AL.Choicepoint.t() | {:mark, scope()} | {:method_mark, scope()} | :implies_mark

  @type failure_score() :: {non_neg_integer(), 0 | 1, non_neg_integer()}
  @type failure_candidate() ::
          {failure_score(), {:call, failure_call()} | {:diagnostic, term()}}

  typedstruct enforce: true do
    field(:active_choicepoint, AL.Choicepoint.t(), enforce: true)
    field(:choicepoint_stack, [stack_entry()], default: [])
    field(:tx_id, non_neg_integer(), enforce: true, default: 0)
    field(:transaction_object, AL.Var.t() | nil, default: nil)
    field(:trace, AL.Trace.t(), default: %AL.Trace{})
    field(:program, [AL.Goal.t()], enforce: true, default: [])
    field(:diagnostics, [term()], default: [])
    field(:failure_candidate, failure_candidate() | nil, default: nil)
    field(:branch, AL.Branch.t(), default: %AL.Branch{id: :main})
    field(:reductions, non_neg_integer(), default: 0)
    field(:output, [iodata()], default: [])

    field(:source_refs, %{optional(AL.Source.Ref.capture_id()) => AL.Source.Ref.t()},
      default: %{}
    )

    field(:source_anchors, %{optional(AL.Source.Ref.capture_id()) => [non_neg_integer()]},
      default: %{}
    )
  end

  # Stack limit. reductions = machine steps taken so far.
  @max_reductions 2_000_000

  defmacro __using__(_opts) do
    quote do
      import AL
    end
  end

  defdelegate trace(point), to: AL.Trace
  defdelegate untrace(point), to: AL.Trace
  defdelegate notrace(), to: AL.Trace
  defdelegate tracepoints(), to: AL.Trace

  defdelegate await_effect(effect, options \\ []), to: AL.Edge, as: :await

  @doc """
  I run an AL transaction against a live branch.
  Options:
  - `branch: s` runs against branch s
  - `trace: flags` retains the requested composable trace families. Supported
    flags are `:domino` and `:vm`; the default `[]` retains nothing
  - `trace_mode: :no_trace` retains no execution trace (the default)
  - `trace_mode: :derivation_trace` retains calls and constraints for extraction
    and verification
  - `trace_mode: :full_trace` also retains every raw VM goal

  `trace_mode` is a compatibility alias and cannot be combined with `trace`.
  """
  defmacro sigil_AL({:<<>>, _meta, [text]}, []) when is_binary(text), do: text

  defmacro run(opts \\ [], do: program) do
    trace_opts = Keyword.take(opts, [:trace, :trace_mode])

    branch_ast =
      if Keyword.has_key?(opts, :branch) do
        quote do: %AL.Branch{id: unquote(opts[:branch])}
      else
        quote do: AL.Branch.head()
      end

    case program do
      {:sigil_AL, meta, [{:<<>>, _, [text]}, []]} when is_binary(text) ->
        source_run(text, meta, branch_ast, trace_opts, __CALLER__)

      _program ->
        raise CompileError,
          file: __CALLER__.file,
          line: __CALLER__.line,
          description: ~s(AL.run takes AL source: run do ~AL"""...""" end)
    end
  end

  defp source_run(text, meta, branch_ast, trace_opts, caller) do
    first_line = meta[:line] + if(meta[:delimiter] == ~s("""), do: 1, else: 0)

    case AL.Syntax.parse(text, pins: true) do
      {:ok, result} ->
        origin = %{kind: :al_run, file: Path.relative_to_cwd(caller.file), line: first_line}

        quote do
          AL.eval_captured(
            unquote(Macro.escape(result, unquote: true)),
            unquote(text),
            unquote(Macro.escape(origin)),
            nil,
            unquote(branch_ast),
            unquote(trace_opts)
          )
        end

      {:error, error} ->
        raise CompileError,
          file: caller.file,
          line: first_line + (error.line || 1) - 1,
          description: "AL: " <> Exception.message(error)
    end
  end

  def eval_source(text, branch \\ AL.Branch.head(), opts \\ []) do
    with {:ok, result} <- AL.Syntax.parse(text),
         {:ok, source} <- AL.Source.prepare(result, %{kind: :eval_source, label: nil}, text) do
      eval_program(source.program, nil, branch, opts, source)
    end
  end

  @doc false
  @spec eval_captured(
          AL.Syntax.Result.t(),
          String.t(),
          AL.SourceStore.origin(),
          AL.Var.store() | nil,
          AL.Branch.t(),
          keyword()
        ) ::
          {:atomic, {AL.Var.store(), map(), t() | nil}}
          | {:aborted, term()}
          | {:error, term()}
  def eval_captured(result, text, origin, initial_store, branch, opts) do
    case AL.Source.prepare(result, origin, text) do
      {:ok, source} -> eval_program(source.program, initial_store, branch, opts, source)
      {:error, _error} -> eval_program(result.program, initial_store, branch, opts, nil)
    end
  end

  @doc """
  Runs a goal list in a Mnesia transaction. Returns
  `{:atomic, {bindings, constraints, state}}` or `{:aborted, reason}`.

  `heap: words` runs in a capped process and returns bindings only.
  """
  @spec eval([AL.Goal.t()], AL.Var.store() | nil, AL.Branch.t(), keyword()) ::
          {:atomic, {AL.Var.store(), map(), t() | nil}}
          | {:aborted, term()}
          | {:error, String.t()}
  def eval(program, initial_store \\ nil, branch \\ AL.Branch.head(), opts \\ []) do
    eval_program(program, initial_store, branch, opts, nil)
  end

  defp eval_program(program, initial_store, branch, opts, source) do
    case Keyword.pop(opts, :heap) do
      {nil, transaction_opts} ->
        eval_transaction(program, initial_store, branch, transaction_opts, source)

      {heap, transaction_opts} ->
        {pid, ref} =
          spawn_monitor(fn ->
            Process.flag(:max_heap_size, %{size: heap, kill: true, error_logger: false})

            exit({
              :derived,
              shed(eval_program(program, initial_store, branch, transaction_opts, source))
            })
          end)

        receive do
          {:DOWN, ^ref, :process, ^pid, {:derived, result}} ->
            result

          {:DOWN, ^ref, :process, ^pid, _killed} ->
            {:error, "the derivation exceeded #{heap} heap words"}
        end
    end
  end

  defp eval_transaction(program, initial_store, branch, opts, source) do
    store = initial_store || AL.Var.empty_store()
    input_vars = observable_vars(program)
    trace_flags = AL.Trace.flags_from_options!(opts)

    result =
      :mnesia.transaction(fn ->
        AL.ResolutionCache.with_transaction_cache(fn ->
          {tx_id, transaction_object} = AL.Transaction.open(branch)
          source_refs = source_refs(source, tx_id)

          if source != nil do
            :ok = AL.SourceStore.put_text(tx_id, source.text, source.origin, branch)
          end

          result =
            %AL{
              active_choicepoint: %AL.Choicepoint{
                goals: program,
                store: store,
                scope_pointer: 0,
                source_scopes: []
              },
              choicepoint_stack: [{:mark, 0}],
              tx_id: tx_id,
              transaction_object: transaction_object,
              branch: branch,
              trace: AL.Trace.new(trace_flags),
              program: program,
              source_refs: source_refs,
              source_anchors: %{}
            }
            |> start_program()
            |> continue()
            |> finalize_trace()

          if result.active_choicepoint.store == nil do
            :mnesia.abort(format_failure(result))
          else
            if map_size(source_refs) > 0, do: AL.Source.validate_provenance(result)

            AL.Transaction.record(tx_id, transaction_object, branch, :committed)

            {bindings, constraints} =
              format_output_vars(input_vars, result.active_choicepoint.store)

            {bindings, constraints, result}
          end
        end)
      end)

    case result do
      {:atomic, {_bindings, _constraints, %AL{tx_id: tx_id} = state}} ->
        flush_output(state)
        AL.Outbox.committed(branch, tx_id)
        result

      {:aborted, reason} ->
        flush_output(reason)
        record_failed_transaction(branch, source, reason)
    end
  end

  # Mnesia may re-run a transaction fun after a lock conflict, so a goal
  # cannot perform its side effect where it runs. `vm_format` accumulates
  # onto the state a restart discards, and the run flushes once the
  # transaction has actually settled.
  defp flush_output(%AL{output: []}), do: :ok
  defp flush_output(%AL{output: chunks}), do: IO.write(Enum.reverse(chunks))
  defp flush_output(%{state: %AL{} = state}), do: flush_output(state)
  defp flush_output(_other), do: :ok

  # A transaction cannot durably record its own abort, so the one case that
  # needs a second transaction is failure. It mints a fresh identity, since
  # the aborted run's own reservation rolled back with everything else, and
  # retags the reported failure so the id the caller sees is the id the
  # retained source and the failed transaction object were written under.
  defp record_failed_transaction(branch, source, reason) do
    {:atomic, tx_id} =
      :mnesia.transaction(fn ->
        {tx_id, transaction_object} = AL.Transaction.open(branch)

        if source != nil do
          :ok = AL.SourceStore.put_text(tx_id, source.text, source.origin, branch)
        end

        AL.Transaction.record(tx_id, transaction_object, branch, :failed, %{reason: reason})
        tx_id
      end)

    {:aborted, retag_failure(reason, tx_id)}
  end

  defp retag_failure(%{state: %AL{} = state} = reason, tx_id),
    do: %{reason | state: %AL{state | tx_id: tx_id}}

  defp retag_failure(reason, _tx_id), do: reason

  defp source_refs(nil, _tx_id), do: %{}

  defp source_refs(source, tx_id) do
    Map.new(source.refs, fn {capture_id, ref} ->
      {capture_id, %AL.Source.Ref{ref | tx_id: tx_id}}
    end)
  end

  def next_solution(state) do
    input_vars = observable_vars(state.program)

    result =
      :mnesia.transaction(fn ->
        AL.ResolutionCache.with_transaction_cache(fn ->
          tx_id = AL.Command.system_time(state.branch)
          result = %AL{state | tx_id: tx_id} |> backtrack() |> finalize_trace()

          if result.active_choicepoint.store == nil do
            :mnesia.abort(format_failure(result))
          else
            {bindings, constraints} =
              format_output_vars(input_vars, result.active_choicepoint.store)

            {bindings, constraints, result}
          end
        end)
      end)

    case result do
      {:atomic, {_bindings, _constraints, %AL{tx_id: tx_id} = solved}} ->
        flush_output(solved)
        AL.Outbox.committed(state.branch, tx_id)

      other ->
        flush_output(other)
    end

    result
  end

  defp anonymous_variable?(variable),
    do: is_atom(variable) and String.starts_with?(Atom.to_string(variable), "$_@")

  # canonical_names: internal freshened var (e.g. concat's fh_N) -> the
  # observable var it's aliased to. Internal names must never surface.
  defp format_output_vars(input_vars, store) do
    sorted_vars = input_vars |> Enum.reject(&anonymous_variable?/1) |> Enum.sort()

    canonical_names =
      Enum.reduce(sorted_vars, %{}, fn variable, acc ->
        resolved = AL.Var.deref(store, variable)
        if AL.Var.var?(resolved), do: Map.put_new(acc, resolved, variable), else: acc
      end)

    # No alias = purely internal var: label `_N` (Prolog-style opaque),
    # stable/reused so aliasing between two of them stays visible.
    {display_names, n} =
      Enum.reduce(sorted_vars, {canonical_names, 0}, fn variable, {names, n} ->
        variable
        |> AL.Var.subst(store)
        |> AL.Var.find_vars()
        |> MapSet.delete(:"$_")
        |> Enum.sort()
        |> Enum.reduce({names, n}, fn leaf, {names, n} ->
          if Map.has_key?(names, leaf) do
            {names, n}
          else
            {Map.put(names, leaf, AL.Var.var("_#{n + 1}")), n + 1}
          end
        end)
      end)

    {residual_props, residual_variables} =
      AL.Var.Bounds.residual_constraints(store, Map.keys(display_names))

    {display_names, n} =
      Enum.reduce(residual_variables, {display_names, n}, fn variable, {names, n} ->
        if Map.has_key?(names, variable) do
          {names, n}
        else
          {Map.put(names, variable, AL.Var.var("_#{n + 1}")), n + 1}
        end
      end)

    {display_names, _n} = expand_constraint_display_names(display_names, n, store)

    rewrite_unbound = fn resolved -> Map.get(display_names, resolved, resolved) end

    bindings =
      sorted_vars
      |> Enum.map(fn variable -> {variable, AL.Var.subst(variable, store, rewrite_unbound)} end)
      |> Map.new()

    # An unbound-but-constrained var (e.g. `class(o, :class)` leaving `o`
    # open with an isa constraint) otherwise prints identically to a
    # genuinely free one -- surface real constraints under a reserved key,
    # keyed by the same display name shown in `bindings` itself, omitted
    # entirely when nothing has anything to say. `display_names`, not
    # `canonical_names` -- a query var can itself be *bound* to a compound
    # value (e.g. a constructed `%{class: :card, suit: ..., rank: ...}`)
    # while still containing nested open-but-constrained vars; only
    # `display_names` (built via `find_vars`, which walks into bound
    # structures) reaches those, `canonical_names` only covers the case
    # where the query var itself stayed open.
    constraints = constraint_summary(display_names, store, rewrite_unbound)

    relations =
      AL.Var.Bounds.summarize_residual_constraints(store, residual_props, rewrite_unbound)

    constraints =
      if relations == [], do: constraints, else: Map.put(constraints, :relations, relations)

    {bindings, constraints}
  end

  defp expand_constraint_display_names(display_names, n, store) do
    linked_variables =
      display_names
      |> Map.keys()
      |> Enum.flat_map(fn variable ->
        case AL.Var.constraint_set(store, variable) do
          %AL.Var.ConstraintSet{} = set -> constraint_terms(set)
          _ -> []
        end
      end)
      |> Enum.reduce(MapSet.new(), fn link, variables ->
        link
        |> AL.Var.subst(store)
        |> AL.Var.find_vars(variables)
      end)
      |> MapSet.delete(:"$_")
      |> Enum.reject(&Map.has_key?(display_names, &1))
      |> Enum.sort()

    case linked_variables do
      [] ->
        {display_names, n}

      variables ->
        {expanded, next_n} =
          Enum.reduce(variables, {display_names, n}, fn variable, {names, index} ->
            {Map.put(names, variable, AL.Var.var("_#{index + 1}")), index + 1}
          end)

        expand_constraint_display_names(expanded, next_n, store)
    end
  end

  defp constraint_terms(set) do
    [
      set.dif,
      MapSet.to_list(set.direct_class),
      MapSet.to_list(set.isa),
      if(set.domain, do: MapSet.to_list(set.domain), else: []),
      set.super_link,
      set.slot_links
    ]
  end

  defp constraint_summary(canonical_names, store, rewrite_unbound) do
    Enum.reduce(canonical_names, %{}, fn {resolved, display_name}, acc ->
      case AL.Var.constraint_set(store, resolved) do
        %AL.Var.ConstraintSet{} = set ->
          case summarize_constraints(resolved, set, store, rewrite_unbound) do
            empty when map_size(empty) == 0 -> acc
            summary -> Map.put(acc, display_name, summary)
          end

        _ ->
          acc
      end
    end)
  end

  defp summarize_constraints(
         self,
         %AL.Var.ConstraintSet{
           dif: dif,
           direct_class: direct_class,
           isa: isa,
           dispatch: dispatch,
           bounds: bounds,
           domain: domain,
           super_link: super_link,
           slot_links: slot_links,
           keys: keys,
           functor: functor
         },
         store,
         rewrite_unbound
       ) do
    %{}
    |> maybe_put_direct_class(direct_class, store, rewrite_unbound)
    |> maybe_put_isa(isa, store, rewrite_unbound)
    |> maybe_put_dispatch(dispatch)
    |> maybe_put_super(super_link, store, rewrite_unbound)
    |> maybe_put_slots(slot_links, store, rewrite_unbound)
    |> maybe_put_keys(keys, store, rewrite_unbound)
    |> maybe_put_functor(functor, store, rewrite_unbound)
    |> maybe_put_dif(self, dif, store, rewrite_unbound)
    |> maybe_put_bounds(bounds)
    |> maybe_put_domain(domain, store, rewrite_unbound)
  end

  defp maybe_put_direct_class(map, direct_class, store, rewrite_unbound) do
    values = summarize_terms(direct_class, store, rewrite_unbound)
    if values == [], do: map, else: Map.put(map, :class, values)
  end

  defp maybe_put_isa(map, isa, store, rewrite_unbound) do
    values =
      isa
      |> Enum.reject(&AL.Var.Residual.internal_relation_link?/1)
      |> summarize_terms(store, rewrite_unbound)

    if values == [], do: map, else: Map.put(map, :isa, values)
  end

  defp maybe_put_dispatch(map, dispatch) do
    if MapSet.size(dispatch) > 0 do
      entries =
        dispatch
        |> Enum.map(fn {selector, provider} -> %{selector: selector, provider: provider} end)
        |> Enum.sort_by(&{&1.selector, &1.provider})

      Map.put(map, :dispatch, entries)
    else
      map
    end
  end

  defp maybe_put_super(map, nil, _store, _rewrite_unbound), do: map

  defp maybe_put_super(map, {side, other}, store, rewrite_unbound) do
    key = if side == :super, do: :super, else: :subclass
    Map.put(map, key, AL.Var.subst(other, store, rewrite_unbound))
  end

  defp maybe_put_slots(map, slot_links, store, rewrite_unbound) do
    {slots, slot_of} =
      Enum.reduce(slot_links, {%{}, %{}}, fn
        {:slot, key, value}, {slots, slot_of} ->
          {Map.put(slots, key, AL.Var.subst(value, store, rewrite_unbound)), slot_of}

        {:slot_value, key, object}, {slots, slot_of} ->
          {slots, Map.put(slot_of, key, AL.Var.subst(object, store, rewrite_unbound))}
      end)

    map
    |> then(fn summary ->
      if map_size(slots) == 0, do: summary, else: Map.put(summary, :slots, slots)
    end)
    |> then(fn summary ->
      if map_size(slot_of) == 0, do: summary, else: Map.put(summary, :slot_of, slot_of)
    end)
  end

  defp maybe_put_keys(map, keys, _store, _rewrite_unbound) when keys == %{}, do: map

  defp maybe_put_keys(map, keys, store, rewrite_unbound),
    do: Map.put(map, :keys, AL.Var.subst(keys, store, rewrite_unbound))

  defp maybe_put_functor(map, nil, _store, _rewrite_unbound), do: map

  defp maybe_put_functor(map, {name, args}, store, rewrite_unbound),
    do: Map.put(map, :functor, AL.Var.subst([name, args], store, rewrite_unbound))

  defp maybe_put_dif(map, _self, [], _store, _rewrite_unbound), do: map

  defp maybe_put_dif(map, self, dif, store, rewrite_unbound) do
    values =
      Enum.map(dif, fn {a, b} ->
        other = if AL.Var.deref(store, a) == self, do: b, else: a
        AL.Var.subst(other, store, rewrite_unbound)
      end)

    Map.put(map, :dif, values)
  end

  defp maybe_put_bounds(map, {nil, nil}), do: map
  defp maybe_put_bounds(map, bounds), do: Map.put(map, :bounds, bounds)

  defp maybe_put_domain(map, nil, _store, _rewrite_unbound), do: map

  defp maybe_put_domain(map, domain, store, rewrite_unbound) do
    values = summarize_terms(domain, store, rewrite_unbound)
    Map.put(map, :domain, values)
  end

  defp summarize_terms(terms, store, rewrite_unbound) do
    terms
    |> Enum.map(&AL.Var.subst(&1, store, rewrite_unbound))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # A domino Call/Exit's "what's known about this position" -- reuses the
  # exact same constraint_set/summarize_constraints machinery
  # format_output_vars/2 already uses for residual constraints, just per-var
  # rather than across a whole result map. `{:bound, v}` for a term with no
  # open vars left (subst'd as far as the given store can take it --
  # covers a compound arg like a constructed map, not just a bare var);
  # `{:open, summary}` (possibly `%{}`, meaning genuinely unconstrained)
  # for a term that's still an open var at top level.
  def describe_var(term, store) do
    resolved = AL.Var.deref(store, term)

    if AL.Var.var?(resolved) do
      constraints =
        case AL.Var.constraint_set(store, resolved) do
          %AL.Var.ConstraintSet{} = set ->
            summarize_constraints(resolved, set, store, &Function.identity/1)

          _ ->
            %{}
        end

      {:open, constraints}
    else
      {:bound, AL.Var.subst(term, store)}
    end
  end

  # `self`, plus each top-level element of `args` -- *not* `[self | args]`
  # itself, since `args` isn't always a proper list: `send([], :concat, z)`
  # is valid AL (z stays open, letting :list's own clause heads decompose
  # it), and `[self | z]` for an open var z is an *improper* list Enum.*
  # can't walk. When args isn't a list, it's one position in its own
  # right instead of a spine to walk.
  def call_positions(self, args) when is_list(args), do: [self | args]
  def call_positions(self, args), do: [self, args]

  def open_positions(terms, store) do
    terms
    |> AL.Var.find_vars()
    |> Enum.filter(fn var -> AL.Var.var?(AL.Var.deref(store, var)) end)
  end

  def describe_positions(vars, store), do: Map.new(vars, fn v -> {v, describe_var(v, store)} end)

  defp domino_enabled?(state), do: AL.Trace.enabled?(state.trace, :domino)

  @spec backtrack(t()) :: t() | nil
  def backtrack(state) do
    state = traced(state, &AL.JAM.Trace.abandon/0)

    case state.choicepoint_stack do
      [] ->
        %AL{
          state
          | active_choicepoint: %AL.Choicepoint{state.active_choicepoint | store: nil}
        }

      [{:jam_cut, _} | rest] ->
        backtrack(%AL{state | choicepoint_stack: rest})

      [:implies_mark | rest] ->
        backtrack(%AL{state | choicepoint_stack: rest})

      [{:mark, scope} | rest] ->
        state = traced(state, fn -> AL.JAM.Trace.fail(scope, :clause_fail) end)
        backtrack(%AL{state | choicepoint_stack: rest})

      [{:method_mark, scope} | rest] ->
        state = traced(state, fn -> AL.JAM.Trace.fail(scope, :method_fail) end)
        backtrack(%AL{state | choicepoint_stack: rest})

      [choice | rest] ->
        state =
          traced(state, fn ->
            AL.JAM.Trace.resume(choice.scope_pointer)
            if choice.clause, do: AL.JAM.Trace.chosen(choice.scope_pointer, choice.clause)
          end)

        continue(%AL{state | active_choicepoint: choice, choicepoint_stack: rest})
    end
  end

  defp traced(state, fun) do
    {_result, trace} = AL.JAM.Trace.run(state.trace, fun)
    %AL{state | trace: trace}
  end

  @spec continue(t()) :: t() | nil
  def continue(nil), do: nil

  def continue(state) do
    state = traced(state, fn -> AL.JAM.Trace.settle(store(state)) end)

    case state.active_choicepoint do
      _choice when state.reductions > @max_reductions ->
        %AL{
          record_resource_limit(state)
          | active_choicepoint: %AL.Choicepoint{state.active_choicepoint | store: nil}
        }

      %AL.Choicepoint{store: nil} ->
        backtrack(state)

      %AL.Choicepoint{goals: [], suspensions: suspensions} when suspensions == %{} ->
        state

      %AL.Choicepoint{goals: []} ->
        state |> traced(&AL.JAM.Trace.flounder/0) |> backtrack()

      %AL.Choicepoint{goals: [{:resume, snapshot} | ahead]} = choice ->
        state = %AL{state | active_choicepoint: %AL.Choicepoint{choice | goals: ahead}}
        snapshot = AL.JAM.with_store(snapshot, store(state))

        {result, state} =
          run_machine(state, fn ->
            AL.JAM.resume(
              snapshot,
              state.branch,
              @max_reductions - state.reductions,
              machine_context(state)
            )
          end)

        continue(apply_machine_result(result, release_machine_suspensions(state)))
    end
  end

  defp record_resource_limit(state),
    do: %AL{
      state
      | diagnostics: [{:resource_limit_exceeded, @max_reductions} | state.diagnostics]
    }

  defp record_constraint_violation(state, a, b) do
    case AL.Var.diagnose_unify_failure(a, b, store(state), state.branch) do
      nil ->
        resolved_a = AL.Var.deref(store(state), a)
        resolved_b = AL.Var.deref(store(state), b)
        record_diagnostic(state, {:unify_failed, resolved_a, resolved_b})

      violation ->
        record_diagnostic(state, {:constraint_violated, violation})
    end
  end

  defp store(state), do: state.active_choicepoint.store

  @doc false
  @spec record_diagnostic(t(), term()) :: t()
  def record_diagnostic(state, diagnostic) do
    entry = {state.active_choicepoint.scope_pointer, diagnostic}
    state = %AL{state | diagnostics: [entry | state.diagnostics]}

    record_failure_candidate(state, {:diagnostic, diagnostic})
  end

  # Runs without Domino retention have no retained scope tree to recover a failing lineage
  # from. Keep one compact candidate instead: progress through the outermost
  # goal list wins, then a diagnostic beats a generic call at that same goal.
  # This prevents final backtracking into an earlier successful goal from
  # replacing the useful error that was reached farther through the program.
  defp record_failure_candidate(state, candidate) do
    if domino_enabled?(state) do
      state
    else
      diagnostic_priority = if match?({:diagnostic, _}, candidate), do: 1, else: 0
      score = {failure_progress(state), diagnostic_priority, state.reductions}

      failure_candidate =
        case state.failure_candidate do
          nil ->
            {score, candidate}

          {old_score, _old_candidate} when score > old_score ->
            {score, candidate}

          existing ->
            existing
        end

      %AL{state | failure_candidate: failure_candidate}
    end
  end

  defp failure_progress(state), do: state.active_choicepoint.progress

  defp resolve_goal(%Goal.Send{} = goal, store), do: resolve_send(goal, store)

  defp resolve_goal(%Goal.Eq{a: a, b: b} = goal, store),
    do: %Goal.Eq{goal | a: resolve_arg(a, store), b: resolve_arg(b, store)}

  defp resolve_goal(%Goal.IsVar{term: term} = goal, store),
    do: %Goal.IsVar{goal | term: resolve_arg(term, store)}

  defp resolve_goal(%control{} = goal, _store)
       when control in [
              Goal.Not,
              Goal.Or,
              Goal.Implies,
              Goal.Dif,
              Goal.Pass,
              Goal.Fail,
              Goal.Cut
            ],
       do: goal

  defp resolve_goal(goal, store), do: AL.Var.subst(goal, store)

  defp resolve_send(%{object: object, method: method, args: args} = goal, store),
    do: %{
      goal
      | object: AL.Var.subst(object, store),
        method: AL.Var.subst(method, store),
        args: resolve_args(args, store)
    }

  defp resolve_args([arg | args], store), do: [arg | resolve_args(args, store)]

  defp resolve_args(args, store), do: AL.Var.subst(args, store)

  defp resolve_arg(arg, store),
    do: if(AL.Var.var?(arg), do: AL.Var.deref(store, arg), else: arg)

  defp raw_goal({:resume, snapshot}), do: AL.JAM.pending_goals(snapshot)
  defp raw_goal(goal), do: goal

  defp start_program(state) do
    choice = state.active_choicepoint
    goals = [{:resume, AL.JAM.query(choice.goals)}]
    %AL{state | active_choicepoint: %AL.Choicepoint{choice | goals: goals}}
  end

  defp run_machine(state, fun) do
    {result, trace} = AL.JAM.Trace.run(state.trace, fun)
    {result, %AL{state | trace: trace}}
  end

  defp machine_context(state),
    do: %{
      tx_id: state.tx_id,
      transaction_object: state.transaction_object,
      suspensions: state.active_choicepoint.suspensions
    }

  defp release_machine_suspensions(state),
    do: %AL{
      state
      | active_choicepoint: %AL.Choicepoint{state.active_choicepoint | suspensions: %{}}
    }

  def collection_budget, do: @max_reductions

  defp apply_machine_result({:cut, snapshot, [], steps, scope}, state) do
    remaining = Enum.drop_while(state.choicepoint_stack, &(&1 != scope))

    %AL{
      state
      | reductions: state.reductions + steps,
        choicepoint_stack: remaining,
        active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | store: AL.JAM.snapshot_store(snapshot),
            goals: [{:resume, snapshot} | state.active_choicepoint.goals]
        }
    }
  end

  defp apply_machine_result({:mutation, snapshot, choices, steps, operation, arguments}, state) do
    state = install_machine_choices(state, choices)

    state = %AL{
      state
      | reductions: state.reductions + steps,
        active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | store: AL.JAM.snapshot_store(snapshot),
            goals: [{:resume, snapshot} | state.active_choicepoint.goals]
        }
    }

    AL.JAM.Mutation.execute(operation, arguments, state)
  end

  defp apply_machine_result({:diagnostic, snapshot, choices, steps, diagnostic}, state) do
    state = install_machine_choices(state, choices)

    state = %AL{
      state
      | reductions: state.reductions + steps,
        active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | store: AL.JAM.snapshot_store(snapshot)
        }
    }

    state |> record_diagnostic(diagnostic) |> backtrack()
  end

  defp apply_machine_result({:failed, snapshot, steps}, state) do
    choice = state.active_choicepoint

    state = %AL{
      state
      | reductions: state.reductions + steps,
        active_choicepoint: %AL.Choicepoint{choice | store: AL.JAM.snapshot_store(snapshot)}
    }

    state =
      case AL.JAM.failed_call(snapshot) do
        {method, args} ->
          call = {:clause_call, fresh_scope(), method, AL.Var.subst(args, store(state)), %{}}
          record_failure_candidate(state, {:call, call})

        nil ->
          state
      end

    goal = resolve_goal(AL.JAM.failed_goal(snapshot), store(state))

    case goal do
      %Goal.Eq{a: a, b: b} ->
        state |> record_constraint_violation(a, b) |> backtrack()

      %Goal.Send{object: object, method: method, args: args} ->
        call = {:method_call, fresh_scope(), object, method, args, %{}}
        state |> record_failure_candidate({:call, call}) |> backtrack()

      _ ->
        backtrack(state)
    end
  end

  defp apply_machine_result({:waiting, pending, result}, state),
    do: result |> apply_machine_result(state) |> import_machine_suspensions(pending)

  defp apply_machine_result({kind, snapshot, choices, steps}, state)
       when kind in [:suspend, :commit] and elem(snapshot, 6) != %{} do
    {kind, AL.JAM.without_suspensions(snapshot), choices, steps}
    |> apply_machine_result(state)
    |> import_machine_suspensions(AL.JAM.pending(snapshot))
  end

  defp apply_machine_result({:forall, snapshot, choices, steps, solutions}, state) do
    state = install_machine_choices(state, choices)
    next = AL.JAM.forall_continuation(snapshot, solutions, visible_vars(state))

    %AL{
      state
      | reductions: state.reductions + steps,
        active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | store: AL.JAM.snapshot_store(snapshot),
            goals: [{:resume, next} | state.active_choicepoint.goals]
        }
    }
  end

  defp apply_machine_result({:collect, snapshot, choices, steps, child, solutions}, state)
       when elem(snapshot, 6) != %{} do
    {:collect, AL.JAM.without_suspensions(snapshot), choices, steps, child, solutions}
    |> apply_machine_result(state)
    |> import_machine_suspensions(AL.JAM.pending(snapshot))
  end

  defp apply_machine_result({:collect, snapshot, choices, steps, child_result, solutions}, state) do
    condition = AL.JAM.collection_condition(snapshot)

    child = %AL{
      active_choicepoint: %AL.Choicepoint{
        goals: [],
        scope_pointer: 0,
        store: AL.JAM.snapshot_store(snapshot),
        source_scopes: state.active_choicepoint.source_scopes
      },
      choicepoint_stack: [],
      tx_id: state.tx_id,
      branch: state.branch,
      trace: AL.Trace.new(state.trace.flags),
      program: condition
    }

    collected = do_collect(continue(apply_machine_result(child_result, child)), solutions)

    state = install_machine_choices(state, choices)
    state = %AL{state | reductions: state.reductions + steps}

    case collected do
      {:ok, solutions} ->
        if AL.JAM.forall?(snapshot) do
          apply_machine_result({:forall, snapshot, [], 0, solutions}, state)
        else
          {next, new_store} = AL.JAM.collection_continuation(snapshot, solutions, state.branch)

          if is_nil(new_store) do
            backtrack(state)
          else
            %AL{
              state
              | active_choicepoint: %AL.Choicepoint{
                  state.active_choicepoint
                  | store: new_store,
                    goals: [{:resume, next} | state.active_choicepoint.goals]
                }
            }
          end
        end

      :resource_limit_exceeded ->
        resource_limit_abort(state)
    end
  end

  defp apply_machine_result({:commit, snapshot, choices, steps}, state) do
    state = install_machine_choices(state, choices)
    [_mark | remaining] = Enum.drop_while(state.choicepoint_stack, &(&1 != :implies_mark))

    %AL{
      state
      | reductions: state.reductions + steps,
        choicepoint_stack: remaining,
        active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | store: AL.JAM.snapshot_store(snapshot),
            goals: [{:resume, snapshot} | state.active_choicepoint.goals]
        }
    }
  end

  defp apply_machine_result({:ok, store, steps}, state),
    do: apply_machine_result({:answers, store, [], steps}, state)

  defp apply_machine_result({:answers, store, choices, steps}, state) do
    state = install_machine_choices(state, choices)

    %AL{
      state
      | reductions: state.reductions + steps,
        active_choicepoint: %AL.Choicepoint{state.active_choicepoint | store: store}
    }
  end

  defp apply_machine_result({:suspend, snapshot, choices, steps}, state) do
    state = install_machine_choices(state, choices)

    %AL{
      state
      | reductions: state.reductions + steps,
        active_choicepoint: %AL.Choicepoint{
          state.active_choicepoint
          | goals: [{:resume, snapshot} | state.active_choicepoint.goals],
            store: AL.JAM.snapshot_store(snapshot)
        }
    }
  end

  defp install_machine_choices(state, choices) do
    choices =
      Enum.map(choices, fn
        :implies_mark ->
          :implies_mark

        {:jam_cut, _} = mark ->
          mark

        {:trace_fail, :clause_fail, scope} ->
          {:mark, scope}

        {:trace_fail, :method_fail, scope} ->
          {:method_mark, scope}

        {:trace_alternative, scope, seq, nil} ->
          %AL.Choicepoint{
            state.active_choicepoint
            | store: nil,
              clause: seq,
              scope_pointer: scope
          }

        {:trace_alternative, scope, seq, snapshot} ->
          %AL.Choicepoint{machine_choice(state, snapshot) | clause: seq, scope_pointer: scope}

        snapshot ->
          machine_choice(state, snapshot)
      end)

    %AL{state | choicepoint_stack: choices ++ state.choicepoint_stack}
  end

  defp machine_choice(state, snapshot) do
    %AL.Choicepoint{
      state.active_choicepoint
      | goals: [
          {:resume, AL.JAM.without_suspensions(snapshot)}
          | state.active_choicepoint.goals
        ],
        store: AL.JAM.snapshot_store(snapshot),
        clause: AL.JAM.Trace.seq_of(elem(snapshot, 0)),
        scope_pointer:
          AL.JAM.Trace.scope_of(elem(snapshot, 0)) || state.active_choicepoint.scope_pointer
    }
    |> import_choice_suspensions(AL.JAM.pending(snapshot))
  end

  defp import_machine_suspensions(nil, _pending), do: nil

  defp import_machine_suspensions(state, pending),
    do: %AL{
      state
      | active_choicepoint: import_choice_suspensions(state.active_choicepoint, pending)
    }

  defp import_choice_suspensions(choice, pending) do
    suspensions =
      Map.merge(choice.suspensions, pending, fn _key, a, b ->
        a ++ b
      end)

    wake(%AL.Choicepoint{choice | suspensions: suspensions})
  end

  defp wake(%AL.Choicepoint{store: nil} = choice), do: choice

  defp wake(choice) do
    {suspensions, ready} = AL.JAM.Suspension.ready(choice.suspensions, choice.store)
    woken = Enum.map(ready, &{:resume, AL.JAM.wake_frame(&1)})
    %AL.Choicepoint{choice | suspensions: suspensions, goals: woken ++ choice.goals}
  end

  defp from_stored_body(body) when is_list(body), do: Enum.map(body, &AL.Goal.from_stored/1)
  defp from_stored_body(body), do: body

  # Scan clauses with bodies lifted to structs, so stored form never enters the
  # VM. `def`, not `defp` — `AL.JAM.Relation`'s clause relation uses this too.
  def scan_clauses(object, seq, head, body, branch) do
    AL.Object.scan_oapply(object, seq, head, body, branch)
    |> Enum.map(fn {:oapply, id, s, h, b} -> {:oapply, id, s, h, from_stored_body(b)} end)
  end

  # Ground method_id: cacheable, same as providers/3. Var method_id (open
  # query) isn't a stable key — skips the cache.
  def cached_scan_clauses(method_id_pattern, branch) do
    if AL.Var.var?(method_id_pattern) do
      scan_clauses(method_id_pattern, :"$seq", :"$head", :"$body", branch)
    else
      AL.ResolutionCache.fetch_oapply_clauses(branch, method_id_pattern, fn ->
        scan_clauses(method_id_pattern, :"$seq", :"$head", :"$body", branch)
      end)
    end
  end

  # Only bindings may leave the capped process, and a refusal's goal
  # crosses as bounded text.
  defp shed({:atomic, {bindings, constraints, _state}}),
    do: {:atomic, {bindings, constraints, nil}}

  defp shed({:aborted, %{failed_on: goal} = reason}) do
    {:aborted,
     %{
       reason
       | failed_on: goal |> inspect(limit: 8) |> String.slice(0, 200),
         state: nil
     }}
  end

  defp shed(other), do: other

  # Vars a `run` reports. `findall`/`not`/`forall` are local scopes: only a
  # `findall`'s result var escapes.
  defp observable_vars(goals), do: observable_vars(goals, MapSet.new())

  defp observable_vars([goal | rest], acc),
    do: observable_vars(rest, observable_vars(goal, acc))

  defp observable_vars([], acc), do: acc

  defp observable_vars(%Goal.Compound{} = compound, acc),
    do: observable_vars(Goal.lower(compound), acc)

  defp observable_vars(%Goal.Findall{result: result}, acc),
    do: AL.Var.find_vars(result, acc)

  defp observable_vars(%Goal.Not{}, acc), do: acc

  defp observable_vars(%Goal.Forall{}, acc), do: acc

  defp observable_vars(%Goal.Or{or: left, then: right}, acc),
    do: observable_vars(right, observable_vars(left, acc))

  defp observable_vars(
         %Goal.Implies{condition: condition, then: then, otherwise: otherwise},
         acc
       ),
       do: observable_vars(otherwise, observable_vars(then, observable_vars(condition, acc)))

  defp observable_vars(goal, acc), do: AL.Var.find_vars(goal, acc)

  # Prolog copy_term: rename unbound vars fresh, no internal scope names leak.
  # def not defp: GetOapply uses this too.
  def standardize_apart(term) do
    rename =
      term
      |> AL.Var.find_vars()
      |> MapSet.delete(:"$_")
      |> Map.new(fn v -> {v, AL.Var.fresh(:"$_G", "#{fresh_scope()}")} end)

    AL.Var.subst(term, rename)
  end

  # store == nil: exhausted, or this sub-search's own reduction budget ran
  # out (e.g. open-ended findall/not) — resource_limited?/1 distinguishes,
  # reading the freshest diagnostic.
  defp do_collect(state, acc) do
    cond do
      state.active_choicepoint.store != nil ->
        acc = [state.active_choicepoint.store | acc]

        case state.choicepoint_stack do
          [] -> {:ok, Enum.reverse(acc)}
          _ -> do_collect(backtrack(state), acc)
        end

      resource_limited?(state) ->
        :resource_limit_exceeded

      true ->
        {:ok, Enum.reverse(acc)}
    end
  end

  defp resource_limited?(state),
    do: match?([{:resource_limit_exceeded, _} | _], state.diagnostics)

  # Mirrors continue/1's ceiling hit: stamp diagnostic, exhaust active
  # choicepoint, ordinary backtracking takes over.
  defp resource_limit_abort(state) do
    %AL{
      record_resource_limit(state)
      | active_choicepoint: %AL.Choicepoint{state.active_choicepoint | store: nil}
    }
  end

  # Failure reason: unhandled DNU wins, else last goal reached. `:domino`
  # carries the call tree; `:vm` also has raw goals and `:backtrack`/`:flounder`
  # interleaved into the same list, so `failed_on` names the
  # exact goal when that's available and the coarser last domino event
  # (which method/clause failed, not which sub-goal) otherwise. Full state
  # rides along (stripped for heap-capped eval, see shed/1).
  #
  # Resource-limit clause: a VM trace can be huge (one
  # entry per reduction). Only builds the last 20 steps shown; drops
  # choicepoint_stack (not inspectable at that scale anyway).
  defp format_failure(%AL{diagnostics: [{:resource_limit_exceeded, limit} | _]} = state) do
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

  defp format_failure(state) do
    if domino_enabled?(state),
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

    {"label(#{inspect(pretty)}) has nothing to enumerate: no finite bounds, domain, or class.",
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
    case AL.Object.scan_method(:"$native_label_self", :"$native_label_name", method_id, branch) do
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

  def fresh_scope(), do: System.unique_integer([:positive, :monotonic])

  defp visible_vars(%AL{active_choicepoint: choice}) do
    AL.Var.find_vars(Enum.map(choice.goals, &raw_goal/1))
  end

  defp finalize_trace(state), do: %AL{state | trace: AL.JAM.Trace.finalize(state.trace)}
end

defimpl Inspect, for: AL do
  def inspect(%AL{}, _opts) do
    "#AL<>"
  end
end
