defmodule AL.Runner.Driver do
  alias AL.Goal

  # Evaluate the AL program
  def eval_program(program, initial_store, branch, opts, source) do
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
            AL.JAM.start(program, store, %{
              tx_id: tx_id,
              transaction_object: transaction_object,
              branch: branch,
              trace_flags: trace_flags,
              source_refs: source_refs
            })

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

  def next_solution(state) do
    input_vars = observable_vars(state.program)

    result =
      :mnesia.transaction(fn ->
        AL.ResolutionCache.with_transaction_cache(fn ->
          {tx_id, transaction_object} = AL.Record.open(state.branch)

          result = AL.JAM.next_solution(state, tx_id, transaction_object)

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

  defp collect(state, waits, post_commit_work) do
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
end
