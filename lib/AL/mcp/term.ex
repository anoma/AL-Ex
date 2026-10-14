defmodule AL.MCP.Term do
  @moduledoc false

  def decode(%{"type" => "atom", "name" => name}) when is_binary(name) do
    {:ok, String.to_atom(name)}
  end

  def decode(%{"type" => "variable", "name" => name}) when is_binary(name),
    do: {:ok, AL.Var.var(name)}

  def decode(%{"type" => "integer", "value" => value}) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _ -> {:error, "Invalid AL integer"}
    end
  end

  def decode(%{"type" => "float", "value" => value}) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> {:ok, float}
      _ -> {:error, "Invalid AL float"}
    end
  end

  def decode(%{"type" => "binary", "encoding" => "utf8", "value" => value})
      when is_binary(value),
      do: {:ok, value}

  def decode(%{"type" => "binary", "encoding" => "base64", "value" => value})
      when is_binary(value) do
    case Base.decode64(value) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, "Invalid AL binary"}
    end
  end

  def decode(%{"type" => "list", "items" => items} = term) when is_list(items) do
    with {:ok, decoded} <- decode_items(items),
         {:ok, tail} <- decode_tail(term) do
      {:ok, Enum.reduce(Enum.reverse(decoded), tail, fn item, rest -> [item | rest] end)}
    end
  end

  def decode(%{"type" => "tuple", "items" => items}) when is_list(items) do
    with {:ok, decoded} <- decode_items(items), do: {:ok, List.to_tuple(decoded)}
  end

  def decode(%{"type" => "map", "entries" => entries}) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn
      %{"key" => key, "value" => value}, {:ok, map} ->
        with {:ok, decoded_key} <- decode(key),
             {:ok, decoded_value} <- decode(value) do
          {:cont, {:ok, Map.put(map, decoded_key, decoded_value)}}
        else
          error -> {:halt, error}
        end

      _, _ ->
        {:halt, {:error, "Invalid AL map entry"}}
    end)
  end

  def decode(_), do: {:error, "Invalid AL term"}

  defp decode_items(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, decoded} ->
      case decode(item) do
        {:ok, value} -> {:cont, {:ok, [value | decoded]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp decode_tail(%{"tail" => tail}), do: decode(tail)
  defp decode_tail(_), do: {:ok, []}

  @spec encode(AL.Var.t()) :: map()
  def encode(term) when is_atom(term) do
    %{"type" => "atom", "name" => Atom.to_string(term)}
  end

  def encode({:"$var", name}), do: %{"type" => "variable", "name" => name}

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
      |> Map.to_list()
      |> Enum.sort_by(fn {key, _value} -> inspect(key) end)
      |> Enum.map(fn {key, value} -> %{"key" => encode(key), "value" => encode(value)} end)

    %{"type" => "map", "entries" => entries}
  end

  @spec encode_bindings(map(), map()) :: map()
  def encode_bindings(bindings, constraints) do
    encoded_bindings =
      bindings
      |> Enum.sort_by(fn {variable, _value} -> variable end)
      |> Enum.map(fn {variable, value} ->
        %{"variable" => encode_binding_key(variable), "value" => encode(value)}
      end)

    {variable_constraints, store_constraints} =
      Enum.split_with(constraints, fn {key, _value} ->
        AL.Var.var?(key) or (is_binary(key) and String.starts_with?(key, "$"))
      end)

    encoded_constraints =
      variable_constraints
      |> Enum.sort_by(fn {variable, _value} ->
        if is_binary(variable), do: variable, else: AL.Var.name(variable)
      end)
      |> Enum.map(fn {variable, value} ->
        %{"variable" => encode_binding_key(variable), "value" => encode(value)}
      end)

    encoded_store =
      store_constraints
      |> Enum.sort_by(fn {key, _value} -> inspect(key) end)
      |> Enum.map(fn {key, value} -> %{"key" => encode(key), "value" => encode(value)} end)

    %{
      "bindings" => encoded_bindings,
      "constraints" => encoded_constraints,
      "store" => encoded_store
    }
  end

  defp encode_binding_key("$" <> name), do: %{"type" => "variable", "name" => name}
  defp encode_binding_key(key), do: encode(key)

  defp list_parts([], items), do: {Enum.reverse(items), []}
  defp list_parts([head | tail], items), do: list_parts(tail, [head | items])
  defp list_parts(tail, items), do: {Enum.reverse(items), tail}
end
