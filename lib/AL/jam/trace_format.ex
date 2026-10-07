defmodule AL.JAM.Trace.Format do
  def instruction({:send, _site, receiver, selector, args}),
    do: "send #{operand(receiver)} #{operand(selector)} #{operand(args)}"

  def instruction({:send_local, send, outputs}),
    do: instruction(send) <> "  outputs: " <> Enum.map_join(outputs, ", ", &"R#{&1}")

  def instruction({:integer_arithmetic, op, dest, left, right, _fallback}),
    do:
      "integer_arithmetic R#{dest} <- #{operand(left)} #{op} #{operand(right)}  [relational fallback]"

  def instruction({:compare, op, left, right}),
    do: "compare #{operand(left)} #{op} #{operand(right)}"

  def instruction({:eq, left, right}), do: "unify #{operand(left)} = #{operand(right)}"
  def instruction({:local, dest, code}), do: "local R#{dest}: " <> instruction(code)
  def instruction(op) when is_atom(op), do: Atom.to_string(op)
  def instruction(op), do: inspect(op, pretty: true, limit: :infinity, width: 100)

  def frame({:root, id}), do: "root/#{id}"
  def frame({:provider, method, cursor, _entry}), do: frame({:provider, method, cursor})
  def frame({:provider, method, {selector, _}}), do: "#{method} #{selector}"
  def frame({:provider, method, _}), do: to_string(method)
  def frame(other), do: inspect(other)

  def registers(slots) do
    slots
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.map_join("  ", fn {value, index} -> "R#{index}=#{value(value)}" end)
    |> case do
      "" -> "(none)"
      registers -> registers
    end
  end

  def operand({:register, index}), do: "R#{index}"
  def operand({:constant, term}), do: value(term)
  def operand({:cons, head, tail}), do: "[" <> operand(head) <> list_tail(tail) <> "]"

  def operand({:map, entries} = term) do
    entries = Map.new(entries)

    case entries do
      %{
        {:constant, :__struct__} => {:constant, AL.Goal.Compound},
        {:constant, :name} => {:constant, name},
        {:constant, :args} => args
      } ->
        "#{name}#{operand(args)}"

      _ ->
        inspect(term, pretty: true, limit: :infinity, width: 100)
    end
  end

  def operand(other), do: inspect(other)

  defp list_tail({:constant, []}), do: ""
  defp list_tail({:cons, head, tail}), do: ", " <> operand(head) <> list_tail(tail)

  defp list_tail({:constant, [head | tail]}),
    do: ", " <> value(head) <> list_tail({:constant, tail})

  defp list_tail(tail), do: " | " <> operand(tail)

  defp value({:"$var", name}), do: "?#{name}"
  defp value({:"$fresh", base, scope}), do: value(base) <> "@#{scope}"
  defp value(term), do: inspect(term, charlists: :as_lists, limit: :infinity)

  def dispatch(path, %{frame: frame, receiver_guard: guard, argument_transfers: transfers}) do
    guard = if guard == :any, do: "dispatch key", else: inspect(guard)

    transfers =
      transfers
      |> Enum.sort()
      |> Enum.map_join("; ", fn {{_method, clause}, slots} ->
        moves =
          slots
          |> Enum.with_index()
          |> Enum.map_join(", ", fn
            {:ignore, index} -> "A#{index} ignored"
            {slot, index} -> "A#{index}->R#{slot}"
          end)

        "clause #{clause}: #{moves}"
      end)

    transfers = if transfers == "", do: "", else: "\n    transfer #{transfers}"
    "dispatch #{path} -> #{frame(frame)}  guard: #{guard}" <> transfers
  end

  def dispatch(path, other), do: "dispatch #{path}: #{inspect(other)}"
end
