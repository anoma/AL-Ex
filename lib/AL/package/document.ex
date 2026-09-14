defmodule AL.Package.Document do
  @moduledoc "The safe, literal manifest for one portable AL package bundle."

  @fields [:name, :version, :deps]

  @enforce_keys @fields
  defstruct @fields

  @type dependency() :: atom() | {atom(), term()}
  @type t() :: %__MODULE__{
          name: atom(),
          version: pos_integer(),
          deps: [dependency()]
        }

  @type parse_error() :: {:invalid_package_document, String.t()}

  @spec render(t()) :: String.t()
  def render(%__MODULE__{} = document) do
    entries =
      Enum.map_join(@fields, ",\n", fn field ->
        "  ##{field} : #{literal(Map.fetch!(document, field))}"
      end)

    "Package {\n" <> entries <> "\n}\n"
  end

  @spec parse(String.t()) :: {:ok, t()} | {:error, parse_error()}
  def parse(text) when is_binary(text) do
    with {:ok, body} <- body(text),
         {:ok, metadata} <- literal_metadata(body),
         :ok <- fields(metadata),
         document <- struct!(__MODULE__, metadata),
         :ok <- validate(document) do
      {:ok, document}
    end
  end

  def parse(_text), do: invalid("document must be text")

  defp body(text) do
    text = String.trim(text)

    case text do
      "Package {" <> rest ->
        with {:ok, closing} <- AL.Source.Scanner.close_index(rest, 0, ?{, ?}),
             "" <-
               rest |> binary_part(closing + 1, byte_size(rest) - closing - 1) |> String.trim() do
          {:ok, rest |> binary_part(0, closing) |> String.trim("\n")}
        else
          :error -> invalid("header is not terminated by a closing brace")
          _ -> invalid("unexpected content after the package header")
        end

      _ ->
        invalid("expected a Package header")
    end
  end

  defp literal_metadata(body) do
    normalized =
      body
      |> String.split("\n")
      |> Enum.map_join("\n", &Regex.replace(~r/^(\s*)#(\w+)\s*:/, &1, "\\1\\2:"))

    with {:ok, quoted} <- Code.string_to_quoted("[\n" <> normalized <> "\n]"),
         true <- Macro.quoted_literal?(quoted),
         {metadata, []} when is_list(metadata) <- Code.eval_quoted(quoted),
         true <- Keyword.keyword?(metadata) do
      {:ok, metadata}
    else
      {:error, reason} -> invalid("invalid header metadata: #{inspect(reason)}")
      _ -> invalid("header metadata must be a literal keyword list")
    end
  end

  defp fields(metadata) do
    keys = Keyword.keys(metadata)

    cond do
      length(keys) != length(Enum.uniq(keys)) ->
        invalid("header metadata contains duplicate fields")

      MapSet.new(keys) != MapSet.new(@fields) ->
        invalid("header fields must be exactly #{inspect(@fields)}")

      true ->
        :ok
    end
  end

  defp validate(%__MODULE__{} = document) do
    with :ok <- atom(document.name, "name must be an atom"),
         :ok <- positive_integer(document.version, "version must be a positive integer"),
         :ok <- dependencies(document.deps) do
      :ok
    end
  end

  defp dependencies(value) when is_list(value) do
    cond do
      not Enum.all?(value, &valid_dependency?/1) ->
        invalid("deps must contain package names or {name, requirement} pairs")

      duplicated?(Enum.map(value, &dependency_name/1)) ->
        invalid("dependency names must be unique")

      true ->
        :ok
    end
  end

  defp dependencies(_value), do: invalid("deps must be a list")

  defp valid_dependency?(name) when is_atom(name), do: true

  defp valid_dependency?({name, _requirement}) when is_atom(name), do: true

  defp valid_dependency?(_dependency), do: false

  defp dependency_name(name) when is_atom(name), do: name
  defp dependency_name({name, _requirement}), do: name

  defp duplicated?(values), do: length(values) != length(Enum.uniq(values))

  defp atom(value, _message) when is_atom(value), do: :ok
  defp atom(_value, message), do: invalid(message)

  defp positive_integer(value, _message) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(_value, message), do: invalid(message)

  defp literal(value),
    do: inspect(value, pretty: true, width: 98, limit: :infinity, printable_limit: :infinity)

  defp invalid(message), do: {:error, {:invalid_package_document, message}}
end
