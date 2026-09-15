defmodule AL.Edge.File do
  @moduledoc "I read files outside AL transactions."

  use AL.Edge, provider: :file

  @impl true
  def execute(:read, [path], _context) when is_binary(path), do: File.read(path)

  def execute(:read, arguments, _context),
    do: {:error, {:invalid_file_read_arguments, arguments}}

  def execute(operation, arguments, _context),
    do: {:error, {:unsupported_file_effect, operation, arguments}}
end
