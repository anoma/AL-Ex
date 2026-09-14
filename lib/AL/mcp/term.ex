defmodule AL.MCP.Term do
  @moduledoc false

  @spec encode(AL.Var.t()) :: map()
  def encode(term) when is_atom(term) do
    if AL.Var.var?(term) do
      %{"type" => "variable", "name" => AL.Var.name(term)}
    else
      %{"type" => "atom", "name" => Atom.to_string(term)}
    end
  end

  def encode({:"$fresh", _base, _scope} = variable) do
    %{"type" => "variable", "name" => AL.Var.name(variable)}
  end

  def encode(term) when is_integer(term) do
    %{"type" => "integer", "value" => Integer.to_string(term)}
  end

  def encode(term) when is_float(term) do
    %{"type" => "float", "value" => :erlang.float_to_binary(term, [:short])}
  end

  def encode(term) when is_binary(term) do
    if String.valid?(term) do
      %{"type" => "binary", "encoding" => "utf8", "value" => term}
    else
      %{"type" => "binary", "encoding" => "base64", "value" => Base.encode64(term)}
    end
  end

  def encode([]), do: %{"type" => "list", "items" => []}

  def encode([_head | _tail] = term) do
    case list_parts(term, []) do
      {items, []} ->
        %{"type" => "list", "items" => Enum.map(items, &encode/1)}

      {items, tail} ->
        %{
          "type" => "list",
          "items" => Enum.map(items, &encode/1),
          "tail" => encode(tail)
        }
    end
  end

  def encode(term) when is_tuple(term) do
    %{"type" => "tuple", "items" => term |> Tuple.to_list() |> Enum.map(&encode/1)}
  end

  def encode(term) when is_map(term) do
    entries =
      term
      |> Enum.sort_by(fn {key, _value} -> inspect(key) end)
      |> Enum.map(fn {key, value} -> %{"key" => encode(key), "value" => encode(value)} end)

    %{"type" => "map", "entries" => entries}
  end

  @spec encode_bindings(AL.Var.store()) :: map()
  def encode_bindings(bindings) do
    constraints = Map.get(bindings, :"$constraints", %{})

    encoded_bindings =
      bindings
      |> Map.delete(:"$constraints")
      |> Enum.sort_by(fn {variable, _value} -> AL.Var.name(variable) end)
      |> Enum.map(fn {variable, value} ->
        %{"variable" => encode(variable), "value" => encode(value)}
      end)

    encoded_constraints =
      constraints
      |> Enum.sort_by(fn {variable, _value} -> AL.Var.name(variable) end)
      |> Enum.map(fn {variable, value} ->
        %{"variable" => encode(variable), "value" => encode(value)}
      end)

    %{"bindings" => encoded_bindings, "constraints" => encoded_constraints}
  end

  defp list_parts([], items), do: {Enum.reverse(items), []}
  defp list_parts([head | tail], items), do: list_parts(tail, [head | items])
  defp list_parts(tail, items), do: {Enum.reverse(items), tail}
end
