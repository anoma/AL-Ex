defmodule AL.Runner.Result do
  def transaction({:atomic, {_, _, state}} = result, children) do
    %AL{
      handle: state.transaction_object,
      kind: :transaction,
      result: result,
      children: children
    }
  end

  def transaction({:aborted, reason} = result, []) do
    handle =
      case reason do
        %{state: %AL.JAM.State{transaction_object: object}} -> object
        _ -> nil
      end

    %AL{handle: handle, kind: :transaction, result: result}
  end

  def future(handle, %AL{result: {:atomic, {_, _, state}}, children: children}) do
    %AL{
      handle: handle,
      kind: :transaction,
      result: {:atomic, state.transaction_object},
      children: children
    }
  end

  def future(handle, %AL{result: {:aborted, reason}}) do
    message =
      if is_map(reason), do: Map.get(reason, :message, inspect(reason)), else: inspect(reason)

    %AL{handle: handle, kind: :transaction, result: {:aborted, message}}
  end

  def effect(handle, result), do: %AL{handle: handle, kind: :effect, result: result}

  def wait_error(handle, reason),
    do: %AL{handle: handle, kind: :completion, result: {:error, reason}}

  def to_stored(%AL{
        handle: handle,
        kind: kind,
        result: {status, value},
        children: children
      }) do
    %{
      handle: handle,
      kind: kind,
      status: status,
      value: value,
      children: Enum.map(children, &to_stored/1)
    }
  end

  def from_stored(%{handle: handle, kind: kind, status: status, value: value, children: children}) do
    %AL{
      handle: handle,
      kind: kind,
      result: {status, value},
      children: Enum.map(children, &from_stored/1)
    }
  end
end
