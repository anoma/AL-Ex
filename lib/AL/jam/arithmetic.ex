defmodule AL.JAM.Arithmetic do
  def select({:eq_into, destination, source, _side} = fallback) do
    case source do
      {:map,
       [
         {{:constant, :args}, args},
         {{:constant, :name}, {:constant, op}},
         {{:constant, :__struct__}, {:constant, AL.Goal.Compound}}
       ]}
      when op in [:+, :-, :*] ->
        case args do
          {:cons, a, {:cons, b, {:constant, []}}} ->
            select_binary(op, destination, a, b, fallback)

          {:cons, a, {:constant, [b]}} ->
            select_binary(op, destination, a, {:constant, b}, fallback)

          _ ->
            fallback
        end

      _ ->
        fallback
    end
  end

  def select({:compare, op, {:register, input}, {:constant, bound}}) when is_number(bound),
    do: {:compare, op, input, bound, :left}

  def select({:compare, op, {:constant, bound}, {:register, input}}) when is_number(bound),
    do: {:compare, reverse(op), input, bound, :right}

  def select({:dif, {:register, input}, {:constant, bound}}) when is_number(bound),
    do: {:dif, input, bound, :left}

  def select({:dif, {:constant, bound}, {:register, input}}) when is_number(bound),
    do: {:dif, input, bound, :right}

  def select({:numeric_tests, value, tests, fallback}),
    do:
      {:numeric_tests, value, tests,
       fallback |> Tuple.to_list() |> Enum.map(&select/1) |> List.to_tuple()}

  def select(instruction), do: instruction

  def reverse(:=), do: :=
  def reverse(:<), do: :>
  def reverse(:<=), do: :>=
  def reverse(:>), do: :<
  def reverse(:>=), do: :<=

  defp select_binary(op, destination, a, b, fallback) do
    if scalar?(a) and scalar?(b),
      do: {:integer_arithmetic, op, destination, a, b, fallback},
      else: fallback
  end

  defp scalar?({:register, _}), do: true
  defp scalar?({:constant, value}), do: is_integer(value)
  defp scalar?(_), do: false

  def integer(operand, slots, store) do
    case operand do
      {:map,
       [
         {{:constant, :args}, args},
         {{:constant, :name}, {:constant, op}},
         {{:constant, :__struct__}, {:constant, AL.Goal.Compound}}
       ]} ->
        expression(op, args, slots, store)

      {:constant, value} when is_integer(value) ->
        value

      {:register, index} ->
        case elem(slots, index) do
          value when is_integer(value) -> value
          value -> resolved_integer(value, store)
        end

      _ ->
        :fallback
    end
  end

  defp resolved_integer(value, store) do
    case AL.Var.deref(store, value) do
      value when is_integer(value) -> value
      _ -> :fallback
    end
  end

  defp expression(op, {:cons, left, {:cons, right, {:constant, []}}}, slots, store)
       when op in [:+, :-, :*] do
    binary(op, left, right, slots, store)
  end

  defp expression(op, {:cons, left, {:constant, [right]}}, slots, store)
       when op in [:+, :-, :*] do
    binary(op, left, {:constant, right}, slots, store)
  end

  defp expression(op, {:cons, value, {:constant, []}}, slots, store)
       when op in [:+, :-] do
    case integer(value, slots, store) do
      value when is_integer(value) -> if op == :-, do: -value, else: value
      _ -> :fallback
    end
  end

  defp expression(_, _, _, _), do: :fallback

  defp binary(op, left, right, slots, store) do
    with left when is_integer(left) <- integer(left, slots, store),
         right when is_integer(right) <- integer(right, slots, store) do
      case op do
        :+ -> left + right
        :- -> left - right
        :* -> left * right
      end
    else
      _ -> :fallback
    end
  end
end
