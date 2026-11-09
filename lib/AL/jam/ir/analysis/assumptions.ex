defmodule AL.JAM.IR.Assumptions do
  @moduledoc """
  I am the module which records and checks a method plan's requirements. If the arguments satisfy those requirements, the method can be specialised. The compiler analyses which assumptions the method makes and then associates the plan with these facts, so that it can be reused.
  """

  alias AL.JAM.IR.Call
  alias AL.JAM.Operand
  alias AL.Var

  @type property :: :class | :value
  @type object :: %{
          # The class of the object 
          optional(:class) => atom(),
          # The value of the object exactly
          optional(:value) => term(),
          # Fields on the object
          optional(:fields) => %{optional(term()) => object()}
        }
  # Argument List
  @type t :: [object()]

  @spec put(object(), property(), term(), [term()]) :: object()
  def put(requirements, property, value, field_path \\ [])
  def put(requirements, property, value, []), do: Map.put(requirements, property, value)

  def put(requirements, property, value, [field | rest]) do
    fields = Map.get(requirements, :fields, %{})
    child = put(Map.get(fields, field, %{}), property, value, rest)
    Map.put(requirements, :fields, Map.put(fields, field, child))
  end

  @spec require(t(), non_neg_integer(), property(), term(), [term()]) :: t()
  def require(arguments, position, property, value, field_path \\ []),
    do: List.update_at(arguments, position, &put(&1, property, value, field_path))

  @spec fetch(t(), non_neg_integer(), property(), [term()]) :: {:ok, term()} | :error
  def fetch(arguments, position, property, field_path \\ []),
    do: fetch_property(Enum.at(arguments, position, %{}), property, field_path)

  defp fetch_property(requirements, property, []), do: Map.fetch(requirements, property)

  defp fetch_property(requirements, property, [field | rest]) do
    with {:ok, fields} <- Map.fetch(requirements, :fields),
         {:ok, child} <- Map.fetch(fields, field),
         do: fetch_property(child, property, rest)
  end

  @spec accepts?(t(), Call.t()) :: boolean()
  def accepts?(arguments, call), do: accepts?(arguments, call.arguments, call.slots, call.store)

  @spec accepts?(t(), term(), tuple(), Var.store()) :: boolean()
  def accepts?([], _arguments, _slots, _store), do: true

  def accepts?([requirements | rest], {:cons, _operand, tail}, slots, store)
      when requirements == %{},
      do: accepts?(rest, tail, slots, store)

  def accepts?([requirements | rest], {:cons, operand, tail}, slots, store) do
    accepts_object?(requirements, operand, slots, store) and accepts?(rest, tail, slots, store)
  end

  def accepts?(requirements, operand, slots, store),
    do: accepts_values?(requirements, Operand.shallow(operand, slots, store), slots, store)

  defp accepts_values?([], _values, _slots, _store), do: true

  defp accepts_values?([requirements | rest], [_value | tail], slots, store)
       when requirements == %{},
       do: accepts_values?(rest, tail, slots, store)

  defp accepts_values?([requirements | rest], [value | tail], slots, store) do
    accepts_object?(requirements, {:constant, value}, slots, store) and
      accepts_values?(rest, tail, slots, store)
  end

  defp accepts_values?(requirements, value, slots, store) do
    case Var.deref(store, value) do
      [_ | _] = values -> accepts_values?(requirements, values, slots, store)
      _ -> Enum.all?(requirements, &(&1 == %{}))
    end
  end

  defp accepts_object?(requirements, _operand, _slots, _store) when requirements == %{}, do: true

  defp accepts_object?(requirements, operand, slots, store) do
    Enum.all?(requirements, fn
      {:fields, fields} ->
        Enum.all?(fields, fn {field, requirements} ->
          case Call.field(operand, field, slots, store) do
            {:ok, child} -> accepts_object?(requirements, child, slots, store)
            :unknown -> false
          end
        end)

      {property, value} ->
        Call.observe(operand, property, slots, store) === {:ok, value}
    end)
  end
end
