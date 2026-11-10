defmodule AL.Edge.Source do
  @moduledoc "I commit source definitions with AL validation and acceptance in the same transaction."

  use AL.Edge, provider: :source

  @impl AL.Edge
  def execute(:save, [source, text, receiver], %{branch: branch, effect_id: effect}) do
    with {:ok, document} <- AL.Syntax.document(text),
         true <- MapSet.size(AL.Var.find_vars(document)) == 0 do
      program =
        send_source(source, :validate_definition, [document]) <>
          "\n" <> text <> "\n" <> send_source(receiver, :saved, [source, text])

      case AL.run(program, branch, caused_by: [effect], source_tag: :source_edit) do
        %AL{handle: transaction, result: {:atomic, _}} -> {:ok, transaction}
        %AL{result: {:aborted, reason}} -> {:error, message(reason)}
        {:error, reason} -> {:error, message(reason)}
      end
    else
      false -> {:error, "A definition must have ground class metadata."}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  defp send_source(receiver, selector, arguments) do
    AL.Syntax.Printer.goal(%AL.Goal.Send{
      object: receiver,
      method: selector,
      args: arguments
    }) <> "."
  end

  defp message(%AL.Syntax.Error{} = reason), do: Exception.message(reason)
  defp message(reason) when is_binary(reason), do: reason
  defp message(%{message: reason}) when is_binary(reason), do: reason
  defp message(reason), do: inspect(reason)
end
