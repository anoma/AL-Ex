defmodule AL.Serialisation.Document.Method do
  @moduledoc "One ordered AL method clause as authored declaration and body text."

  @enforce_keys [:selector, :declaration, :body]
  defstruct [:selector, :declaration, :body]

  @type t() :: %__MODULE__{
          selector: term(),
          declaration: String.t(),
          body: String.t()
        }
end

defmodule AL.Serialisation.Document do
  @moduledoc """
  Encodes one AL definition owner as a Tonel document.

  The owner prefix and the type definition are generated. Everything a body can
  depend on is authored text: the declaration right of `>>` carries the selector
  and head, and the body is verbatim between brackets. Clause order is file
  order.
  """

  alias AL.Serialisation.Document.Method

  @enforce_keys [:kind, :owner, :metaclass, :supers, :ivars, :comment, :methods]
  defstruct [:kind, :owner, :metaclass, :supers, :ivars, :comment, :methods]

  @type kind() :: :class | :extension
  @type t() :: %__MODULE__{
          kind: kind(),
          owner: term(),
          metaclass: term() | nil,
          supers: [term()],
          ivars: [term()],
          comment: String.t() | nil,
          methods: [Method.t()]
        }

  @type parse_error() :: {:invalid_document, String.t()}

  @spec render(t()) :: String.t()
  def render(%__MODULE__{} = document) do
    [render_comment(document.comment), render_type(document)]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(Enum.map(document.methods, &render_method(document.owner, &1)))
    |> Enum.join("\n\n")
  end

  @spec parse(String.t()) :: {:ok, t()} | {:error, parse_error()}
  def parse(text) when is_binary(text) do
    with {:ok, comment, rest} <- take_comment(text),
         {:ok, type, metadata, rest} <- take_header(rest),
         {:ok, document} <- document(type, metadata, comment),
         {:ok, methods} <- take_methods(document.owner, rest, []) do
      {:ok, %{document | methods: methods}}
    end
  end

  def parse(_text), do: invalid("document must be text")

  defp render_comment(nil), do: nil
  defp render_comment(comment), do: "\"\n" <> comment <> "\n\""

  defp render_type(%__MODULE__{kind: :class} = document) do
    render_metadata("Class",
      name: document.owner,
      superclass: document.supers,
      metaclass: document.metaclass,
      ivars: document.ivars
    )
  end

  defp render_type(%__MODULE__{kind: :extension} = document) do
    metadata = [name: document.owner]

    metadata =
      if document.supers == [], do: metadata, else: metadata ++ [superclass: document.supers]

    render_metadata("Extension", metadata)
  end

  defp render_method(owner, %Method{} = method),
    do: "#{literal(owner)} >> #{method.declaration} [\n" <> method.body <> "\n]"

  defp render_metadata(name, metadata) do
    entries =
      Enum.map_join(metadata, ",\n", fn {key, value} -> "  ##{key} : #{literal(value)}" end)

    name <> " {\n" <> entries <> "\n}"
  end

  defp literal(value),
    do: inspect(value, pretty: false, limit: :infinity, printable_limit: :infinity)

  defp take_comment("\"\n" <> rest) do
    case scan_comment(rest, []) do
      {:ok, comment, rest} -> {:ok, comment, String.trim_leading(rest, "\n")}
      :error -> invalid("class comment is not terminated by a lone quote")
    end
  end

  defp take_comment(text), do: {:ok, nil, text}

  defp scan_comment(text, lines) do
    case String.split(text, "\n", parts: 2) do
      ["\"", rest] -> {:ok, Enum.reverse(lines) |> Enum.join("\n"), rest}
      ["\""] -> {:ok, Enum.reverse(lines) |> Enum.join("\n"), ""}
      [line, rest] -> scan_comment(rest, [line | lines])
      [_line] -> :error
    end
  end

  defp take_header(text) do
    with {:ok, name, after_open} <- header_start(text),
         {:ok, closing} <- AL.Source.Scanner.close_index(after_open, 0, ?{, ?}) do
      body = binary_part(after_open, 0, closing) |> String.trim("\n")
      rest = binary_part(after_open, closing + 1, byte_size(after_open) - closing - 1)

      case literal_metadata(body) do
        {:ok, metadata} -> {:ok, name, metadata, rest}
        {:error, reason} -> invalid(reason)
      end
    else
      :error -> invalid("header is not terminated by a closing brace")
      {:error, _reason} = error -> error
    end
  end

  defp header_start("Class {" <> rest), do: {:ok, "Class", rest}
  defp header_start("Class{" <> rest), do: {:ok, "Class", rest}
  defp header_start("Extension {" <> rest), do: {:ok, "Extension", rest}
  defp header_start("Extension{" <> rest), do: {:ok, "Extension", rest}
  defp header_start("{" <> rest), do: {:ok, nil, rest}
  defp header_start(_text), do: invalid("expected a Class or Extension header")

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
      {:error, reason} -> {:error, "invalid header metadata: #{inspect(reason)}"}
      _ -> {:error, "header metadata must be a literal keyword list"}
    end
  end

  defp document("Class", metadata, comment) do
    with {:ok, owner} <- required(metadata, :name),
         {:ok, metaclass} <- required(metadata, :metaclass),
         {:ok, supers} <- list(metadata, :superclass),
         {:ok, ivars} <- list(metadata, :ivars) do
      {:ok,
       %__MODULE__{
         kind: :class,
         owner: owner,
         metaclass: metaclass,
         supers: supers,
         ivars: ivars,
         comment: comment,
         methods: []
       }}
    end
  end

  defp document("Extension", metadata, comment) do
    with {:ok, owner} <- required(metadata, :name),
         {:ok, supers} <- optional_list(metadata, :superclass, []) do
      {:ok,
       %__MODULE__{
         kind: :extension,
         owner: owner,
         metaclass: nil,
         supers: supers,
         ivars: [],
         comment: comment,
         methods: []
       }}
    end
  end

  defp document(_name, _metadata, _comment),
    do: invalid("document must start with Class or Extension")

  defp take_methods(owner, text, methods) do
    trimmed = String.trim_leading(text, "\n")

    if String.trim(trimmed) == "" do
      {:ok, Enum.reverse(methods)}
    else
      with {:ok, rest} <- take_method_metadata(trimmed),
           {:ok, method, rest} <- take_method(owner, rest) do
        take_methods(owner, rest, [method | methods])
      end
    end
  end

  defp take_method_metadata("{" <> _ = text) do
    case take_header(text) do
      {:ok, nil, _metadata, rest} ->
        {:ok, String.trim_leading(rest, "\n")}

      {:ok, name, _metadata, _rest} ->
        invalid("unexpected #{name} header after the document header")

      error ->
        error
    end
  end

  defp take_method_metadata(text), do: {:ok, text}

  defp take_method(owner, text) do
    with {:ok, line, rest} <- take_line(text),
         {:ok, declaration} <- declaration(owner, line),
         {:ok, selector} <- selector(declaration),
         {:ok, body, rest} <- AL.Serialisation.Document.Scanner.scan(rest) do
      {:ok, %Method{selector: selector, declaration: declaration, body: body}, rest}
    end
  end

  defp take_line(text) do
    case String.split(text, "\n", parts: 2) do
      [line, rest] -> {:ok, line, rest}
      [_line] -> invalid("method declaration must be followed by a body")
    end
  end

  defp declaration(owner, line) do
    prefix = "#{literal(owner)} >> "

    cond do
      not String.starts_with?(line, prefix) ->
        invalid("method declaration must start with #{String.trim_trailing(prefix)}")

      not String.ends_with?(line, " [") ->
        invalid("method declaration must end with an opening bracket")

      true ->
        {:ok,
         line
         |> binary_part(byte_size(prefix), byte_size(line) - byte_size(prefix))
         |> binary_part(0, byte_size(line) - byte_size(prefix) - 2)}
    end
  end

  defp selector(declaration) do
    case Code.string_to_quoted("{" <> declaration <> "}") do
      {:ok, {selector, _head}} -> {:ok, selector}
      {:ok, {:{}, _meta, [selector | _rest]}} -> {:ok, selector}
      _ -> invalid("method declaration must be a selector and a head")
    end
  end

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

  defp optional_list(metadata, key, default) do
    case Keyword.fetch(metadata, key) do
      {:ok, value} when is_list(value) -> {:ok, value}
      {:ok, _value} -> invalid("#{key} metadata must be a list")
      :error -> {:ok, default}
    end
  end

  defp invalid(message), do: {:error, {:invalid_document, message}}
end
