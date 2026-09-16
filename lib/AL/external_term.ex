defmodule AL.ExternalTerm do
  @moduledoc false

  def encode(_socket, term) do
    ensure_portable!(term)
    :erlang.term_to_binary(term)
  end

  def decode(_socket, <<131, 80, _rest::binary>>),
    do: raise(ArgumentError, "compressed external terms are not accepted")

  def decode(_socket, binary) when is_binary(binary) do
    term = :erlang.binary_to_term(binary, [:safe])
    ensure_portable!(term)
    term
  end

  defp ensure_portable!(term) do
    if portable?(term), do: term, else: raise(ArgumentError, "term is not portable AL data")
  end

  defp portable?(term)
       when is_pid(term) or is_port(term) or is_reference(term) or is_function(term),
       do: false

  defp portable?([]), do: true
  defp portable?([head | tail]), do: portable?(head) and portable?(tail)

  defp portable?(term) when is_map(term) do
    Enum.all?(term, fn {key, value} -> portable?(key) and portable?(value) end)
  end

  defp portable?(term) when is_tuple(term) do
    term |> Tuple.to_list() |> Enum.all?(&portable?/1)
  end

  defp portable?(term), do: not AL.Var.var?(term)
end
