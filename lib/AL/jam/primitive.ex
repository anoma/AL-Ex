defmodule AL.JAM.Primitive do
  alias AL.Goal

  def arguments(operation, operands, slots, store),
    do: AL.JAM.IR.Access.arguments(:primitive, operation, operands, slots, store)

  def output(:string_codes, 0, [_string, codes], store) do
    case code_list(codes, [], store) do
      {:ok, list} -> {:ok, List.to_string(list)}
      _ -> :fallback
    end
  end

  def output(:string_codes, 1, [string, _codes], _store) when is_binary(string) do
    if String.valid?(string), do: {:ok, String.to_charlist(string)}, else: :fallback
  end

  def output(:atom_string, 0, [_atom, string], _store) when is_binary(string) do
    if String.valid?(string), do: {:ok, String.to_atom(string)}, else: :fallback
  end

  def output(:atom_string, 1, [atom, _string], _store) when is_atom(atom) do
    if AL.Var.var?(atom), do: :fallback, else: {:ok, Atom.to_string(atom)}
  end

  def output(:map_pairs, 0, [_map, pairs], _store) do
    case pairs_map(pairs, %{}) do
      {:ok, map} -> {:ok, map}
      _ -> :fallback
    end
  end

  def output(:map_pairs, 1, [map, _pairs], _store) when is_map(map) and not is_struct(map),
    do: {:ok, map |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {key, value} -> [key, value] end)}

  def output(_, _, _, _), do: :fallback

  def execute(:equal, [a, b], store, _branch),
    do: if(a == b, do: {:ok, store}, else: :fail)

  def execute(:variant, [a, b], store, _branch),
    do: if(variant_renaming(a, b, {%{}, %{}}), do: {:ok, store}, else: :fail)

  def execute(:atom, [term], store, _branch),
    do: if(is_atom(term) and not AL.Var.var?(term), do: {:ok, store}, else: :fail)

  def execute(:functor, [term, name, args], store, branch),
    do: result(AL.Var.add_functor(store, term, name, args, branch))

  def execute(:string_codes, [string, codes], store, branch) do
    cond do
      is_binary(string) and String.valid?(string) ->
        result(AL.JAM.Unification.unify(String.to_charlist(string), codes, store, branch))

      AL.Var.var?(string) ->
        case code_list(codes, [], store) do
          {:ok, list} -> result(AL.Var.unify(string, List.to_string(list), store, branch))
          {:open, var} -> {:suspend, [string, var]}
          :error -> :fail
        end

      true ->
        :fail
    end
  end

  def execute(:atom_string, [atom, string], store, branch) do
    cond do
      is_atom(atom) and not AL.Var.var?(atom) ->
        result(AL.Var.unify(Atom.to_string(atom), string, store, branch))

      AL.Var.var?(atom) and is_binary(string) and String.valid?(string) ->
        result(AL.Var.unify(atom, String.to_atom(string), store, branch))

      AL.Var.var?(atom) and AL.Var.var?(string) ->
        {:suspend, [atom, string]}

      true ->
        :fail
    end
  end

  def execute(:map_pairs, [map, pairs], store, branch) do
    cond do
      is_struct(map) ->
        :fail

      is_map(map) ->
        case pairs_map(pairs, %{}) do
          {:ok, given} ->
            result(AL.Var.unify(map, given, store, branch))

          _ ->
            sorted =
              map |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {key, value} -> [key, value] end)

            result(AL.Var.unify(pairs, sorted, store, branch))
        end

      not AL.Var.var?(map) ->
        :fail

      true ->
        case pairs_map(pairs, %{}) do
          {:ok, built} -> result(AL.Var.unify(map, built, store, branch))
          {:open, blocking} -> {:suspend, [map | blocking]}
          :error -> :fail
        end
    end
  end

  def goal(:map_pairs, [map, pairs]), do: %Goal.OApply{method_id: :map_pairs, args: [map, pairs]}

  def goal(:equal, [a, b]), do: %Goal.Equal{a: a, b: b}
  def goal(:atom, [term]), do: %Goal.Atom{term: term}
  def goal(:variant, [a, b]), do: %Goal.Variant{a: a, b: b}
  def goal(:functor, [term, name, args]), do: %Goal.Functor{term: term, name: name, args: args}
  def goal(:string_codes, [string, codes]), do: %Goal.StringCodes{string: string, codes: codes}
  def goal(:atom_string, [atom, string]), do: %Goal.AtomString{atom: atom, string: string}

  defp pairs_map([], map), do: {:ok, map}

  defp pairs_map([[key, value] | rest], map) do
    cond do
      MapSet.size(AL.Var.find_vars(key)) != 0 -> {:open, MapSet.to_list(AL.Var.find_vars(key))}
      Map.has_key?(map, key) -> :error
      true -> pairs_map(rest, Map.put(map, key, value))
    end
  end

  defp pairs_map([pair | _rest], _map) do
    if AL.Var.var?(pair), do: {:open, [pair]}, else: :error
  end

  defp pairs_map(tail, _map), do: if(AL.Var.var?(tail), do: {:open, [tail]}, else: :error)

  defp result(nil), do: :fail
  defp result(store), do: {:ok, store}

  defp code_list(term, codes, store) do
    case AL.Var.deref(store, term) do
      [] ->
        {:ok, Enum.reverse(codes)}

      [code | rest] ->
        code = AL.Var.deref(store, code)

        cond do
          AL.Var.var?(code) -> {:open, code}
          codepoint?(code) -> code_list(rest, [code | codes], store)
          true -> :error
        end

      rest ->
        if AL.Var.var?(rest), do: {:open, rest}, else: :error
    end
  end

  defp codepoint?(code),
    do: is_integer(code) and code in 0..0x10FFFF and code not in 0xD800..0xDFFF

  defp variant_renaming(a, b, renaming) do
    case {AL.Var.var?(a), AL.Var.var?(b)} do
      {true, true} -> rename_variant(a, b, renaming)
      {false, false} -> variant_structure(a, b, renaming)
      _ -> nil
    end
  end

  defp rename_variant(:"$_", _b, renaming), do: renaming
  defp rename_variant(_a, :"$_", renaming), do: renaming

  defp rename_variant(a, b, {forward, backward} = renaming) do
    case {Map.fetch(forward, a), Map.fetch(backward, b)} do
      {{:ok, ^b}, {:ok, ^a}} -> renaming
      {:error, :error} -> {Map.put(forward, a, b), Map.put(backward, b, a)}
      _ -> nil
    end
  end

  defp variant_structure([ha | ta], [hb | tb], renaming) do
    with renaming when not is_nil(renaming) <- variant_renaming(ha, hb, renaming) do
      variant_renaming(ta, tb, renaming)
    end
  end

  defp variant_structure(a, b, renaming)
       when is_tuple(a) and is_tuple(b) and tuple_size(a) == tuple_size(b),
       do: variant_renaming(Tuple.to_list(a), Tuple.to_list(b), renaming)

  defp variant_structure(a, b, renaming)
       when is_map(a) and is_map(b) and map_size(a) == map_size(b) do
    if Enum.sort(Map.keys(a)) == Enum.sort(Map.keys(b)) do
      Enum.reduce_while(Map.keys(a), renaming, fn key, renaming ->
        case variant_renaming(Map.fetch!(a, key), Map.fetch!(b, key), renaming) do
          nil -> {:halt, nil}
          renaming -> {:cont, renaming}
        end
      end)
    end
  end

  defp variant_structure(a, a, renaming), do: renaming
  defp variant_structure(_a, _b, _renaming), do: nil
end
