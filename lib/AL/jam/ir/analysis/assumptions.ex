defmodule AL.JAM.IR.Assumptions do
  @moduledoc """
  I am the module which records and checks a method plan's requirements. If the arguments satisfy those requirements, the method can be specialised. The compiler analyses which assumptions the method makes and then associates the plan with these facts, so that it can be reused.
  """

  alias AL.JAM.IR.Call

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
  def accepts?(arguments, call), do: accepts_arguments?(arguments, call, 0)

  defp accepts_arguments?([], _call, _position), do: true

  defp accepts_arguments?([requirements | rest], call, position) when map_size(requirements) == 0,
    do: accepts_arguments?(rest, call, position + 1)

  defp accepts_arguments?([requirements | rest], call, position) do
    with {:ok, operand} <- Call.argument(call, position) do
      accepts_object?(requirements, operand, call) and
        accepts_arguments?(rest, call, position + 1)
    else
      _ -> false
    end
  end

  defp accepts_object?(requirements, operand, call) do
    Enum.all?(requirements, fn
      {:fields, fields} ->
        Enum.all?(fields, fn {field, requirements} ->
          case Call.field(operand, field, call.slots, call.store) do
            {:ok, child} -> accepts_object?(requirements, child, call)
            :unknown -> false
          end
        end)

      {property, value} ->
        Call.observe(operand, property, call.slots, call.store) === {:ok, value}
    end)
  end
end
