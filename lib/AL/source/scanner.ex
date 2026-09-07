defmodule AL.Source.Scanner do
  @moduledoc """
  Finds a matching delimiter by depth, consuming strings, heredocs, comments and
  character literals whole so a delimiter inside one never changes the depth.

  Scanning rather than parsing is deliberate: decompiled bodies can contain
  `RAW(...)` terms that are not valid source, and they still have to be sliced.
  """

  @spec close_index(String.t(), non_neg_integer(), byte(), byte()) ::
          {:ok, non_neg_integer()} | :error
  def close_index(text, index, open, close) when is_binary(text),
    do: walk(text, index, open, close, 1, nil)

  defp walk(text, index, open, close, depth, previous) do
    if index >= byte_size(text) do
      :error
    else
      case :binary.at(text, index) do
        ?" -> quoted(text, index, open, close, depth, ?")
        ?' -> quoted(text, index, open, close, depth, ?')
        ?# -> walk(text, line_end(text, index), open, close, depth, ?#)
        ?? -> character(text, index, open, close, depth, previous)
        ^open -> walk(text, index + 1, open, close, depth + 1, open)
        ^close when depth == 1 -> {:ok, index}
        ^close -> walk(text, index + 1, open, close, depth - 1, close)
        byte -> walk(text, index + 1, open, close, depth, byte)
      end
    end
  end

  defp quoted(text, index, open, close, depth, quote_byte) do
    delimiter = String.duplicate(<<quote_byte>>, 3)

    if binary_slice(text, index, 3) == delimiter do
      case :binary.match(text, delimiter, scope: {index + 3, byte_size(text) - index - 3}) do
        {found, _length} -> walk(text, found + 3, open, close, depth, quote_byte)
        :nomatch -> :error
      end
    else
      case closing_quote(text, index + 1, quote_byte) do
        {:ok, after_quote} -> walk(text, after_quote, open, close, depth, quote_byte)
        :error -> :error
      end
    end
  end

  defp closing_quote(text, index, quote_byte) do
    cond do
      index >= byte_size(text) -> :error
      :binary.at(text, index) == ?\\ -> closing_quote(text, index + 2, quote_byte)
      :binary.at(text, index) == quote_byte -> {:ok, index + 1}
      true -> closing_quote(text, index + 1, quote_byte)
    end
  end

  defp character(text, index, open, close, depth, previous) do
    if identifier_byte?(previous) do
      walk(text, index + 1, open, close, depth, ??)
    else
      width = if binary_slice(text, index + 1, 1) == "\\", do: 3, else: 2
      walk(text, index + width, open, close, depth, ??)
    end
  end

  defp identifier_byte?(byte) when is_integer(byte),
    do: byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte == ?_

  defp identifier_byte?(_previous), do: false

  defp line_end(text, index) do
    case :binary.match(text, "\n", scope: {index, byte_size(text) - index}) do
      {found, _length} -> found
      :nomatch -> byte_size(text)
    end
  end

  @spec top_level_commas(String.t()) :: [non_neg_integer()]
  def top_level_commas(text) when is_binary(text), do: commas(text, 0, 0, nil, [])

  defp commas(text, index, depth, previous, found) do
    if index >= byte_size(text) do
      Enum.reverse(found)
    else
      case :binary.at(text, index) do
        ?" -> jump(text, index, depth, previous, found, ?")
        ?' -> jump(text, index, depth, previous, found, ?')
        ?# -> commas(text, line_end(text, index), depth, ?#, found)
        ?? -> skip_character(text, index, depth, previous, found)
        byte when byte in [?(, ?[, ?{] -> commas(text, index + 1, depth + 1, byte, found)
        byte when byte in [?), ?], ?}] -> commas(text, index + 1, depth - 1, byte, found)
        ?, when depth == 0 -> commas(text, index + 1, depth, ?,, [index | found])
        byte -> commas(text, index + 1, depth, byte, found)
      end
    end
  end

  defp jump(text, index, depth, _previous, found, quote_byte) do
    delimiter = String.duplicate(<<quote_byte>>, 3)

    next =
      if binary_slice(text, index, 3) == delimiter do
        case :binary.match(text, delimiter, scope: {index + 3, byte_size(text) - index - 3}) do
          {position, _length} -> position + 3
          :nomatch -> byte_size(text)
        end
      else
        case closing_quote(text, index + 1, quote_byte) do
          {:ok, position} -> position
          :error -> byte_size(text)
        end
      end

    commas(text, next, depth, quote_byte, found)
  end

  defp skip_character(text, index, depth, previous, found) do
    if identifier_byte?(previous) do
      commas(text, index + 1, depth, ??, found)
    else
      width = if binary_slice(text, index + 1, 1) == "\\", do: 3, else: 2
      commas(text, index + width, depth, ??, found)
    end
  end
end
