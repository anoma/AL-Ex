defmodule AL.Serialisation.Document.Scanner do
  @moduledoc "Finds the end of a bracketed Tonel method body."

  @spec scan(String.t()) ::
          {:ok, String.t(), String.t()} | {:error, {:invalid_document, String.t()}}
  def scan(text) when is_binary(text) do
    case AL.Source.Scanner.close_index(text, 0, ?[, ?]) do
      {:ok, closing} ->
        body = text |> binary_part(0, closing) |> String.trim_trailing("\n")
        rest = binary_part(text, closing + 1, byte_size(text) - closing - 1)
        {:ok, body, rest}

      :error ->
        {:error, {:invalid_document, "method body is not terminated by a closing bracket"}}
    end
  end
end
