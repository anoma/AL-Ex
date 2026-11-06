defmodule AL.JAM.Text do
  alias AL.{Term, Var}

  def execute(:vm_text_concat, [left, right, whole], store, branch) do
    cond do
      not Term.text_pattern?(left) or not Term.text_pattern?(right) or
          not Term.text_pattern?(whole) ->
        :fail

      is_binary(whole) and is_binary(left) ->
        with {:ok, rest} <- match_prefix(left, whole), do: unify(right, rest, store, branch)

      is_binary(whole) and is_binary(right) ->
        size = byte_size(whole) - byte_size(right)

        if size >= 0 do
          case whole do
            <<prefix::binary-size(size), ^right::binary>> ->
              unify(left, prefix, store, branch)

            _ ->
              :fail
          end
        else
          :fail
        end

      is_binary(left) and is_binary(right) ->
        unify(whole, left <> right, store, branch)

      is_binary(whole) ->
        {:stores, splits(whole, whole, 0, left, right, store, branch)}

      left == "" ->
        unify(whole, right, store, branch)

      right == "" ->
        unify(whole, left, store, branch)

      true ->
        suspend([left, right, whole])
    end
  end

  def execute(:vm_text_code, [text, code, rest], store, branch) do
    cond do
      not Term.text_pattern?(text) or not Term.text_pattern?(rest) ->
        :fail

      not Var.var?(code) and not codepoint?(code) ->
        :fail

      is_binary(text) ->
        case text do
          <<first::utf8, tail::binary>> ->
            with {:ok, store} <- unify(code, first, store, branch),
                 do: unify(rest, tail, store, branch)

          _ ->
            :fail
        end

      codepoint?(code) and is_binary(rest) ->
        unify(text, <<code::utf8, rest::binary>>, store, branch)

      text == rest ->
        :fail

      true ->
        suspend([text, code, rest])
    end
  end

  def execute(:vm_text_length, [text, size], store, branch) do
    cond do
      not Term.text_pattern?(text) ->
        :fail

      not Var.var?(size) and (not is_integer(size) or size < 0) ->
        :fail

      is_binary(text) ->
        case count(text, 0) do
          :error -> :fail
          count -> unify(size, count, store, branch)
        end

      size == 0 ->
        unify(text, "", store, branch)

      true ->
        suspend([text, size])
    end
  end

  def execute(:vm_text_join, [fragments, text], store, branch) do
    if Term.text_pattern?(text) do
      case fragments(fragments, store, []) do
        {:ok, pieces} -> unify(text, IO.iodata_to_binary(pieces), store, branch)
        {:open, variable} -> {:suspend, [variable]}
        :error -> :fail
      end
    else
      :fail
    end
  end

  def match_prefix(prefix, input) when is_binary(prefix) and is_binary(input) do
    size = byte_size(prefix)

    case input do
      <<^prefix::binary-size(size), rest::binary>> -> {:ok, rest}
      _ -> :fail
    end
  end

  def match_prefix(_, _), do: :fallback

  defp splits(whole, rest, offset, left, right, store, branch) do
    prefix = binary_part(whole, 0, offset)
    next = Var.unify([left, right], [prefix, rest], store, branch)

    more =
      case rest do
        <<_code::utf8, tail::binary>> ->
          splits(whole, tail, byte_size(whole) - byte_size(tail), left, right, store, branch)

        _ ->
          []
      end

    if next, do: [next | more], else: more
  end

  defp fragments(value, store, pieces) do
    case Var.deref(store, value) do
      [] ->
        {:ok, Enum.reverse(pieces)}

      [piece | rest] ->
        case Var.subst(piece, store) do
          text when is_binary(text) ->
            fragments(rest, store, [text | pieces])

          value ->
            case MapSet.to_list(Var.find_vars(value)) do
              [variable | _] -> {:open, variable}
              [] -> :error
            end
        end

      variable ->
        if Var.var?(variable), do: {:open, variable}, else: :error
    end
  end

  defp count(<<_code::utf8, rest::binary>>, total), do: count(rest, total + 1)
  defp count("", total), do: total
  defp count(_, _), do: :error

  defp codepoint?(value),
    do: is_integer(value) and value in 0..0x10FFFF and value not in 0xD800..0xDFFF

  defp suspend(values) do
    case values |> Var.find_vars() |> MapSet.to_list() do
      [] -> :fail
      variables -> {:suspend, variables}
    end
  end

  defp unify(left, right, store, branch) do
    case Var.unify(left, right, store, branch) do
      nil -> :fail
      next -> {:ok, next}
    end
  end
end
