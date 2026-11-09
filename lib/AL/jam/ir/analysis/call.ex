defmodule AL.JAM.IR.Call do
  use TypedStruct

  alias AL.{Dispatch, Var}
  alias AL.JAM.Operand
  alias AL.JAM.IR.Assumptions

  typedstruct do
    field(:dispatch, term())
    field(:arguments, term())
    field(:slots, tuple(), default: {})
    field(:store, Var.store(), default: %{})
  end

  def new(receiver, selector, arguments \\ []) do
    {arguments, slots, store} =
      case arguments do
        {:operands, args, slots, store} -> {args, slots, store}
        values -> {{:constant, values}, {}, %{}}
      end

    %__MODULE__{
      dispatch: Dispatch.receiver_key(receiver, selector),
      arguments: {:cons, {:constant, receiver}, arguments},
      slots: slots,
      store: store
    }
  end

  @spec derive(t(), non_neg_integer(), Assumptions.property(), [term()]) ::
          {:ok, term()} | :unknown
  def derive(call, position, property, field_path \\ []) do
    with {:ok, operand} <- argument(call, position, field_path),
         do: observe(operand, property, call.slots, call.store)
  end

  @spec satisfies?(t(), map()) :: boolean()
  def satisfies?(call, %{dispatch: dispatch, arguments: arguments}) do
    call.dispatch == dispatch and Assumptions.accepts?(arguments, call)
  end

  def satisfies?(_call, _requirements), do: false

  def argument(call, position, field_path \\ []) do
    with {:ok, operand} <- operand_at(call.arguments, position, call),
         do: field_operand(operand, field_path, call.slots, call.store)
  end

  defp operand_at({:cons, head, _tail}, 0, _call), do: {:ok, head}

  defp operand_at({:cons, _head, tail}, index, call),
    do: operand_at(tail, index - 1, call)

  defp operand_at(operand, index, call),
    do: value_at(Operand.shallow(operand, call.slots, call.store), index, call.store)

  defp value_at([head | _tail], 0, _store), do: {:ok, {:constant, head}}

  defp value_at([_head | tail], index, store),
    do: value_at(Var.deref(store, tail), index - 1, store)

  defp value_at(_, _, _), do: :unknown

  def observe(operand, property, slots, store, field_path \\ []) do
    with {:ok, operand} <- field_operand(operand, field_path, slots, store),
         do: observe_property(operand, property, slots, store)
  end

  defp field_operand(operand, [], _slots, _store), do: {:ok, operand}

  defp field_operand(operand, [field | rest], slots, store) do
    with {:ok, child} <- field(operand, field, slots, store),
         do: field_operand(child, rest, slots, store)
  end

  def field({:map, fields}, key, _slots, _store) do
    with {:ok, fields} <- operand_fields(fields),
         {:ok, child} <- Map.fetch(fields, key),
         do: {:ok, child},
         else: (_ -> :unknown)
  end

  def field({:cons, _, _}, _key, _slots, _store), do: :unknown
  def field({:tuple, _}, _key, _slots, _store), do: :unknown
  def field({:destination, _}, _key, _slots, _store), do: :unknown

  def field(operand, key, slots, store) do
    value = Operand.shallow(operand, slots, store)

    fields =
      if Var.var?(value) do
        case Var.constraint_set(store, value) do
          %Var.ConstraintSet{keys: keys} -> {:ok, keys}
          nil -> :unknown
        end
      else
        value_fields(value)
      end

    with {:ok, fields} <- fields,
         {:ok, child} <- Map.fetch(fields, key),
         do: {:ok, {:constant, Var.deref(store, child)}},
         else: (_ -> :unknown)
  end

  defp observe_property({:cons, _, _}, :class, _slots, _store), do: {:ok, :list}
  defp observe_property({:cons, _, _}, _property, _slots, _store), do: :unknown
  defp observe_property({:tuple, _}, _property, _slots, _store), do: :unknown
  defp observe_property({:destination, _}, _property, _slots, _store), do: :unknown

  defp observe_property({:map, fields}, :class, slots, store) do
    with {:ok, fields} <- operand_fields(fields) do
      class = Map.get(fields, :class, {:constant, :map})
      known_class(Operand.shallow(class, slots, store))
    end
  end

  defp observe_property({:map, _}, _property, _slots, _store), do: :unknown

  defp observe_property(operand, property, slots, store),
    do: property(Operand.shallow(operand, slots, store), property, store)

  defp property(value, :value, _store)
       when is_atom(value) or is_number(value) or is_binary(value),
       do: {:ok, value}

  defp property(value, :class, _store) when is_struct(value),
    do: known_class(Dispatch.structural_class(value))

  defp property(value, :class, store) when is_map(value) do
    with {:ok, fields} <- value_fields(value),
         do: known_class(Var.deref(store, Map.get(fields, :class, :map)))
  end

  defp property(value, property, store) do
    if Var.var?(value) do
      constrained_property(Var.constraint_set(store, value), property, store)
    else
      case property do
        :class ->
          known_class(Dispatch.structural_class(value))

        :value ->
          resolved = Var.subst(value, store)
          if MapSet.size(Var.find_vars(resolved)) == 0, do: {:ok, resolved}, else: :unknown
      end
    end
  end

  defp constrained_property(
         %Var.ConstraintSet{integer: true, bounds: {value, value}},
         :value,
         _store
       )
       when is_integer(value),
       do: {:ok, value}

  defp constrained_property(%Var.ConstraintSet{domain: %MapSet{} = domain}, property, store) do
    case MapSet.to_list(domain) do
      [value] when is_atom(value) or is_number(value) or is_binary(value) ->
        property(value, property, store)

      _ ->
        :unknown
    end
  end

  defp constrained_property(_, _, _), do: :unknown

  defp operand_fields(fields) do
    if Enum.all?(fields, fn
         {{:constant, :__struct__}, _} -> false
         {{:constant, _}, _} -> true
         _ -> false
       end),
       do: {:ok, Map.new(fields, fn {{:constant, key}, value} -> {key, value} end)},
       else: :unknown
  end

  defp value_fields(value) when is_map(value) do
    if Map.has_key?(value, :__struct__) or Enum.any?(Map.keys(value), &Var.var?/1),
      do: :unknown,
      else: {:ok, value}
  end

  defp value_fields(_), do: :unknown

  defp known_class(class) when is_atom(class) and not is_nil(class), do: {:ok, class}
  defp known_class(_), do: :unknown
end
