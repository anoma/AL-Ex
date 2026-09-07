defmodule AL.SourceDocument.Method do
  @moduledoc "Generated metadata and source for one ordered AL method clause."

  @enforce_keys [:selector, :method_id, :clause, :source, :provenance]
  defstruct [:selector, :method_id, :clause, :source, :provenance]

  @type t() :: %__MODULE__{
          selector: term(),
          method_id: term(),
          clause: non_neg_integer(),
          source: String.t(),
          provenance: :retained | :decompiled
        }
end

defmodule AL.SourceDocument do
  @moduledoc """
  Encodes one AL definition owner as a Tonel-like document.

  Object metadata is generated from the live tables. Each method record carries
  generated identity and ordering metadata, followed by retained source when it
  exists and an explicitly marked decompiled form otherwise.
  """

  alias AL.SourceDocument.Method

  @enforce_keys [:kind, :owner, :metaclass, :supers, :ivars, :revision, :methods]
  defstruct [:kind, :owner, :metaclass, :supers, :ivars, :revision, :methods]

  @type kind() :: :class | :extension
  @type t() :: %__MODULE__{
          kind: kind(),
          owner: term(),
          metaclass: term() | nil,
          supers: [term()],
          ivars: [term()],
          revision: non_neg_integer(),
          methods: [Method.t()]
        }

  @type parse_error() :: {:invalid_document, String.t()}

  @spec render(t()) :: String.t()
  def render(%__MODULE__{} = document) do
    header =
      case document.kind do
        :class ->
          render_header("Class",
            id: document.owner,
            metaclass: document.metaclass,
            supers: document.supers,
            ivars: document.ivars,
            revision: document.revision
          )

        :extension ->
          render_header("Extension",
            owner: document.owner,
            class: document.metaclass,
            revision: document.revision
          )
      end

    methods = Enum.map_join(document.methods, "\n\n", &render_method/1)
    if methods == "", do: header, else: header <> "\n\n" <> methods
  end

  @spec parse(String.t()) :: {:ok, t()} | {:error, parse_error()}
  def parse(text) when is_binary(text) do
    with {:ok, type, metadata, rest} <- take_header(text),
         {:ok, document} <- document(type, metadata),
         {:ok, methods} <- take_methods(rest, []) do
      {:ok, %{document | methods: methods}}
    end
  end

  def parse(_text), do: invalid("document must be text")

  defp render_method(%Method{} = method) do
    render_header("Method",
      selector: method.selector,
      method: method.method_id,
      clause: method.clause,
      source: method.provenance,
      bytes: byte_size(method.source)
    ) <> "\n[\n" <> method.source <> "\n]"
  end

  defp render_header(name, metadata) do
    entries =
      metadata
      |> Enum.map(fn {key, value} ->
        inspected = inspect(value, pretty: false, limit: :infinity, printable_limit: :infinity)

        "  #{key}: #{inspected}"
      end)
      |> Enum.join(",\n")

    "#{name} {\n#{entries}\n}"
  end

  defp take_header(text) do
    case Regex.run(~r/\A(Class|Extension|Method) \{\n(.*?)^\}/ms, text, return: :index) do
      [{0, length}, {name_start, name_length}, {body_start, body_length}] ->
        name = binary_part(text, name_start, name_length)
        body = binary_part(text, body_start, body_length)
        rest = binary_part(text, length, byte_size(text) - length)

        case literal_metadata(body) do
          {:ok, metadata} -> {:ok, name, metadata, rest}
          {:error, reason} -> invalid(reason)
        end

      _ ->
        invalid("expected a Class, Extension, or Method header")
    end
  end

  defp literal_metadata(body) do
    with {:ok, quoted} <- Code.string_to_quoted("[\n" <> body <> "\n]"),
         true <- Macro.quoted_literal?(quoted),
         {metadata, []} when is_list(metadata) <- Code.eval_quoted(quoted),
         true <- Keyword.keyword?(metadata) do
      {:ok, metadata}
    else
      {:error, reason} -> {:error, "invalid header metadata: #{inspect(reason)}"}
      _ -> {:error, "header metadata must be a literal keyword list"}
    end
  end

  defp document("Class", metadata) do
    with {:ok, owner} <- required(metadata, :id),
         {:ok, metaclass} <- required(metadata, :metaclass),
         {:ok, supers} <- list(metadata, :supers),
         {:ok, ivars} <- list(metadata, :ivars),
         {:ok, revision} <- revision(metadata) do
      {:ok,
       %__MODULE__{
         kind: :class,
         owner: owner,
         metaclass: metaclass,
         supers: supers,
         ivars: ivars,
         revision: revision,
         methods: []
       }}
    end
  end

  defp document("Extension", metadata) do
    with {:ok, owner} <- required(metadata, :owner),
         {:ok, class} <- required(metadata, :class),
         {:ok, revision} <- revision(metadata) do
      {:ok,
       %__MODULE__{
         kind: :extension,
         owner: owner,
         metaclass: class,
         supers: [],
         ivars: [],
         revision: revision,
         methods: []
       }}
    end
  end

  defp document("Method", _metadata), do: invalid("document must start with Class or Extension")

  defp take_methods(rest, methods) do
    cond do
      rest == "" ->
        {:ok, Enum.reverse(methods)}

      String.trim(rest) == "" ->
        {:ok, Enum.reverse(methods)}

      String.starts_with?(rest, "\n\n") ->
        rest = binary_part(rest, 2, byte_size(rest) - 2)

        with {:ok, "Method", metadata, after_header} <- take_header(rest),
             {:ok, method, after_method} <- take_method(metadata, after_header) do
          take_methods(after_method, [method | methods])
        else
          {:ok, type, _metadata, _rest} ->
            invalid("unexpected #{type} header after document header")

          error ->
            error
        end

      true ->
        invalid("expected a Method record after the document header")
    end
  end

  defp take_method(metadata, "\n[\n" <> framed) do
    with {:ok, selector} <- required(metadata, :selector),
         {:ok, method_id} <- required(metadata, :method),
         {:ok, clause} <- non_negative_integer(metadata, :clause),
         {:ok, provenance} <- provenance(metadata),
         {:ok, bytes} <- non_negative_integer(metadata, :bytes),
         true <- byte_size(framed) >= bytes + 2,
         source <- binary_part(framed, 0, bytes),
         "\n]" <- binary_part(framed, bytes, 2) do
      rest = binary_part(framed, bytes + 2, byte_size(framed) - bytes - 2)

      {:ok,
       %Method{
         selector: selector,
         method_id: method_id,
         clause: clause,
         source: source,
         provenance: provenance
       }, rest}
    else
      false -> invalid("Method source is shorter than its bytes metadata")
      _ -> invalid("Method source does not match its bytes metadata")
    end
  end

  defp take_method(_metadata, _rest), do: invalid("Method source must be enclosed by [ and ]")

  defp required(metadata, key) do
    case Keyword.fetch(metadata, key) do
      {:ok, value} -> {:ok, value}
      :error -> invalid("missing #{key} metadata")
    end
  end

  defp list(metadata, key) do
    with {:ok, value} <- required(metadata, key), true <- is_list(value) do
      {:ok, value}
    else
      false -> invalid("#{key} metadata must be a list")
      error -> error
    end
  end

  defp revision(metadata), do: non_negative_integer(metadata, :revision)

  defp non_negative_integer(metadata, key) do
    with {:ok, value} <- required(metadata, key), true <- is_integer(value) and value >= 0 do
      {:ok, value}
    else
      false -> invalid("#{key} metadata must be a non-negative integer")
      error -> error
    end
  end

  defp provenance(metadata) do
    with {:ok, value} <- required(metadata, :source),
         true <- value in [:retained, :decompiled] do
      {:ok, value}
    else
      false -> invalid("source metadata must be :retained or :decompiled")
      error -> error
    end
  end

  defp invalid(message), do: {:error, {:invalid_document, message}}
end
