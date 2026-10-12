defmodule AL.Runner.Completion do
  def await(target, options \\ []) do
    branch = Keyword.get(options, :branch, AL.Branch.head())
    branch = if is_atom(branch), do: %AL.Branch{id: branch}, else: branch
    timeout = Keyword.get(options, :timeout, 5_000)

    wait_target =
      case AL.Record.completion_transaction(target, branch) do
        {:ok, transaction} -> transaction
        _ -> target
      end

    if timeout == :infinity or (is_integer(timeout) and timeout >= 0) do
      case AL.Outbox.await(branch, wait_target, timeout) do
        :ready ->
          case read(target, branch) do
            {:ok, %AL{} = outcome} -> outcome
            {:ok, {:error, reason}} -> AL.Runner.Result.wait_error(target, reason)
            :pending -> AL.Runner.Result.wait_error(target, {:completion_pending, target})
          end

        {:error, reason} ->
          AL.Runner.Result.wait_error(target, reason)
      end
    else
      AL.Runner.Result.wait_error(target, {:invalid_completion_timeout, timeout})
    end
  end

  def read(target, branch) do
    case :mnesia.transaction(fn -> AL.Object.read_slots(target, branch) end) do
      {:atomic, [{:slots, ^target, %{tx: _tx, status: :committed}}]} ->
        {:ok, %AL{handle: target, kind: :transaction, result: {:atomic, target}}}

      {:atomic, [{:slots, ^target, %{tx: _tx, status: :failed, reason: reason}}]} ->
        {:ok, %AL{handle: target, kind: :transaction, result: {:aborted, reason}}}

      {:atomic, [{:slots, ^target, %{status: :completed, outcome: %{children: _} = outcome}}]} ->
        {:ok, AL.Runner.Result.from_stored(outcome)}

      {:atomic, [{:slots, ^target, %{status: :completed, outcome: %{status: :ok, value: value}}}]} ->
        {:ok, AL.Runner.Result.effect(target, {:ok, value})}

      {:atomic,
       [{:slots, ^target, %{status: :completed, outcome: %{status: :error, reason: reason}}}]} ->
        {:ok, AL.Runner.Result.effect(target, {:error, reason})}

      {:atomic, [{:slots, ^target, %{status: :pending, completion_transaction: transaction}}]} ->
        case read(transaction, branch) do
          {:ok, %AL{result: {:aborted, reason}}} ->
            {:ok, AL.Runner.Result.wait_error(target, {:completion_transaction_failed, reason})}

          _ ->
            :pending
        end

      {:atomic, [{:slots, ^target, %{status: status}}]}
      when status in [:pending, :ready, :waiting, :running] ->
        :pending

      {:atomic, []} ->
        {:ok, {:error, {:completion_not_found, target}}}

      {:atomic, rows} ->
        {:ok, {:error, {:invalid_completion, target, rows}}}

      {:aborted, reason} ->
        {:ok, {:error, {:completion_read_failed, reason}}}
    end
  end
end
