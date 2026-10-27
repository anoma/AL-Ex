defmodule AL do
  alias AL.Goal
  alias AL.JAM.State

  @moduledoc """
  Runs AL programs and returns their transaction result with explicitly awaited completions.
  """

  defstruct [:handle, :kind, :result, children: []]

  @type t() :: %__MODULE__{
          handle: term(),
          kind: :transaction | :effect | :completion,
          result: term(),
          children: [t()]
        }

  defmacro __using__(_opts) do
    quote do
      import AL
    end
  end

  defdelegate trace(point), to: AL.Trace
  defdelegate untrace(point), to: AL.Trace
  defdelegate notrace(), to: AL.Trace
  defdelegate tracepoints(), to: AL.Trace
  defdelegate await_completion(target, options \\ []), to: AL.Runner.Completion, as: :await
  defdelegate await_effect(effect, options \\ []), to: AL.Edge, as: :await

  @doc """
  Executes AL source text in one transaction.

  `bindings:` supplies initial values for named AL variables. `branch:` selects
  a branch, and `trace:` selects retained trace families. The returned `%AL{}`
  contains the transaction's result and its explicitly awaited completions.
  `wait_timeout:` limits each wait in milliseconds (default 5,000) or is `:infinity`.
  A child's failure or timeout leaves its parent's committed result intact.
  """
  def run(text) when is_binary(text), do: run(text, AL.Branch.head(), [])

  def run(text, opts) when is_binary(text) and is_list(opts) do
    {branch, opts} = Keyword.pop(opts, :branch)
    run(text, branch || AL.Branch.head(), opts)
  end

  def run(text, branch) when is_binary(text), do: run(text, branch, [])

  def run(text, branch, opts) when is_binary(text) do
    {wait_timeout, opts} = Keyword.pop(opts, :wait_timeout, 5_000)
    {bindings, transaction_opts} = Keyword.pop(opts, :bindings, %{})
    {source_tag, transaction_opts} = Keyword.pop(transaction_opts, :source_tag)
    initial_store = Map.new(bindings, fn {name, value} -> {AL.Var.var(name), value} end)
    branch = if match?(%AL.Branch{}, branch), do: branch, else: %AL.Branch{id: branch}
    origin = if source_tag == nil, do: %{kind: :al_text}, else: %{kind: :al_text, tag: source_tag}

    with {:ok, result} <- AL.Syntax.parse(text) do
      eval_with_retained_source(
        result,
        text,
        origin,
        initial_store,
        branch,
        transaction_opts
      )
      |> post_commit(wait_timeout: wait_timeout)
    end
  end

  @doc false
  @spec eval_with_retained_source(
          AL.Syntax.Result.t(),
          String.t(),
          AL.SourceStore.origin(),
          AL.Var.store() | nil,
          AL.Branch.t(),
          keyword()
        ) ::
          {:atomic, {%{String.t() => AL.Var.t()}, map(), State.t()}}
          | {:aborted, term()}
          | {:error, term()}
  def eval_with_retained_source(result, text, origin, initial_store, branch, opts) do
    with {:ok, source} <- AL.Source.prepare(result, origin, text) do
      eval_program(source.program, initial_store, branch, opts, source)
    end
  end

  @doc """
  Evaluates a goal list in a Mnesia transaction without dispatching external work.
  Returns `{:atomic, {bindings, constraints, state}}` or `{:aborted, reason}`.
  Pass a committed result to `AL.post_commit/1` to dispatch its work and collect
  its registered completions.
  """
  @spec eval([AL.Goal.t()], AL.Var.store() | nil, AL.Branch.t(), keyword()) ::
          {:atomic, {%{String.t() => AL.Var.t()}, map(), State.t()}}
          | {:aborted, term()}
  def eval(program, initial_store \\ nil, branch \\ AL.Branch.head(), opts \\ []) do
    eval_program(program, initial_store, branch, opts, nil)
  end

  # Evaluate the AL program
  defp eval_program(program, initial_store, branch, opts, source) do
    Keyword.validate!(opts, [:trace, :run, :caused_by, :transaction_object])

    store = initial_store || AL.Var.empty_store()
    input_vars = observable_vars(program)
    trace_flags = AL.Trace.flags_from_options!(opts)
    lineage = Map.new(Keyword.take(opts, [:run, :caused_by]))
    reserved_transaction = Keyword.get(opts, :transaction_object)

    result =
      :mnesia.transaction(fn ->
        AL.ResolutionCache.with_transaction_cache(fn ->
          {tx_id, transaction_object} = AL.Record.open(branch, reserved_transaction)
          source_refs = source_refs(source, tx_id)

          if source != nil do
            :ok = AL.SourceStore.put_text(tx_id, source.text, source.origin, branch)
          end

          result =
            %State{
              active_choicepoint: %AL.Choicepoint{
                continuations: [],
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
            |> AL.Runner.Driver.execute()

          if result.active_choicepoint.store == nil do
            :mnesia.abort(AL.Diagnostics.format_failure(result))
          else
            if map_size(source_refs) > 0, do: AL.Source.validate_provenance(result)

            %{transaction_slots: transaction_slots, post_commit_work: post_commit_work} =
              AL.JAM.TransactionWork.finalize(result.transaction_work)

            post_commit_work = Map.put(post_commit_work, :transaction, transaction_object)

            if reserved_transaction != nil,
              do: AL.Record.validate_completion!(transaction_object, branch)

            :ok =
              AL.Record.record(
                tx_id,
                transaction_object,
                branch,
                :committed,
                lineage,
                transaction_slots
              )

            {bindings, constraints} =
              AL.Answer.format(input_vars, result.active_choicepoint.store)

            {bindings, constraints, collect(result, transaction_slots.waits, post_commit_work)}
          end
        end)
      end)

    case result do
      {:atomic, _} ->
        result

      {:aborted, reason} ->
        %{transaction_slots: transaction_slots, post_commit_work: post_commit_work} =
          AL.JAM.TransactionWork.new() |> AL.JAM.TransactionWork.finalize()

        {:aborted, failure, transaction_object} =
          AL.Record.failed(
            branch,
            source,
            reason,
            lineage,
            transaction_slots,
            reserved_transaction
          )

        AL.Outbox.dispatch(branch, Map.put(post_commit_work, :transaction, transaction_object))
        {:aborted, failure}
    end
  end

  defp source_refs(nil, _tx_id), do: %{}

  defp source_refs(source, tx_id) do
    Map.new(source.refs, fn {capture_id, ref} ->
      {capture_id, %AL.Source.Ref{ref | tx_id: tx_id}}
    end)
  end

  @spec has_potential_solution?(State.t()) :: boolean()
  def has_potential_solution?(%State{choicepoint_stack: stack}) do
    Enum.any?(stack, &match?(%AL.Choicepoint{}, &1))
  end

  def next_solution(state) do
    input_vars = observable_vars(state.program)

    result =
      :mnesia.transaction(fn ->
        AL.ResolutionCache.with_transaction_cache(fn ->
          {tx_id, transaction_object} = AL.Record.open(state.branch)

          result =
            %State{
              state
              | tx_id: tx_id,
                transaction_object: transaction_object,
                commands: [],
                waits: [],
                transaction_work: AL.JAM.TransactionWork.new(),
                post_commit_work: %{}
            }
            |> AL.Runner.Driver.resume()

          if result.active_choicepoint.store == nil do
            :mnesia.abort(AL.Diagnostics.format_failure(result))
          else
            lineage = AL.Record.lineage(state.transaction_object, state.branch)

            %{transaction_slots: transaction_slots, post_commit_work: post_commit_work} =
              AL.JAM.TransactionWork.finalize(result.transaction_work)

            post_commit_work = Map.put(post_commit_work, :transaction, transaction_object)

            :ok =
              AL.Record.record(
                tx_id,
                transaction_object,
                state.branch,
                :committed,
                lineage,
                transaction_slots
              )

            {bindings, constraints} =
              AL.Answer.format(input_vars, result.active_choicepoint.store)

            {bindings, constraints, collect(result, transaction_slots.waits, post_commit_work)}
          end
        end)
      end)

    post_commit(result)
  end

  def collect(state, waits, post_commit_work) do
    commands = transaction_commands(state.tx_id, state.branch)

    %{
      state
      | commands: commands,
        waits: waits,
        transaction_work: AL.JAM.TransactionWork.new(),
        post_commit_work: post_commit_work
    }
  end

  defp transaction_commands(tx_id, branch) do
    AL.Command.commands_for_transaction(tx_id, branch)
    |> Enum.sort_by(fn {:command, time, _, _} -> time end)
  end

  def notify_outbox({:atomic, {_, _, state}} = result) do
    if :mnesia.is_transaction(),
      do: raise(ArgumentError, "notify_outbox requires a committed transaction")

    AL.Outbox.dispatch(state.branch, state.post_commit_work)

    result
  end

  def notify_outbox(result), do: result

  # Start dependent transactions, elixir process sends, and effects
  def post_commit(result, options \\ []) do
    result |> notify_outbox() |> collect_outcomes(Keyword.get(options, :wait_timeout, 5_000))
  end

  # Decide which variables from the input program will appear in the returned bindings
  defp observable_vars(goals),
    do: goals |> observable_vars(MapSet.new()) |> MapSet.delete({:"$var", "_"})

  defp observable_vars([goal | rest], acc),
    do: observable_vars(rest, observable_vars(goal, acc))

  defp observable_vars([], acc), do: acc

  defp observable_vars(%Goal.FindNSols{count: count, result: result}, acc),
    do: AL.Var.find_vars([count, result], acc)

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

  defp collect_outcomes({:atomic, {_, _, state}} = result, timeout) do
    children =
      Enum.map(state.waits, fn handle ->
        AL.Runner.Completion.await(handle, branch: state.branch, timeout: timeout)
      end)

    AL.Runner.Result.transaction(result, children)
  end

  defp collect_outcomes({:aborted, _} = result, _timeout),
    do: AL.Runner.Result.transaction(result, [])

  defp collect_outcomes(result, _timeout), do: result
  defdelegate backtrack(state), to: AL.Runner.Driver
  defdelegate continue(state), to: AL.Runner.Driver
  defdelegate record_diagnostic(state, diagnostic), to: AL.Runner.Driver
  defdelegate standardize_apart(term), to: AL.Runner.Driver
  defdelegate fresh_scope(), to: AL.Runner.Driver
end
