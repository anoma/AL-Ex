defmodule AL.Definition.Document.Method do
  @moduledoc "One ordered AL method clause as authored declaration and body text."

  @enforce_keys [:selector, :declaration, :body]
  defstruct [:selector, :declaration, :body]

  @type t() :: %__MODULE__{
          selector: term(),
          declaration: String.t(),
          body: String.t()
        }
end

defmodule AL.Definition.Document do
  @moduledoc ~S"""
  Encodes one AL definition owner as an AL source file.

  A file holds leading `#` comment lines, then `@name #{...}.` for a class or
  `@+name #{super => [...]}.` for an extension of a class owned elsewhere, then
  the owner's method clauses. Each clause keeps its authored declaration and
  body text. Clause order is file order.
  """

  alias AL.Definition.Document.Method

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

  @class_options [:super, :metaclass, :ivars]

  @spec render(t()) :: String.t()
  def render(%__MODULE__{} = document) do
    [render_comment(document.comment), render_header(document)]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(
      Enum.map(document.methods, fn method ->
        AL.Syntax.method_text(literal(document.owner), method.declaration, method.body)
      end)
    )
    |> Enum.join("\n\n")
  end

  @spec parse(String.t()) :: {:ok, t()} | {:error, parse_error()}
  def parse(text) when is_binary(text) do
    with {:ok, parsed} <- read(text),
         {:ok, document} <- document(parsed.header, parsed.methods, parsed.comment),
         :ok <- same_owner(document.owner, parsed.methods) do
      {:ok,
       %{
         document
         | methods:
             Enum.map(parsed.methods, fn method ->
               %Method{
                 selector: method.selector,
                 declaration: method.declaration,
                 body: method.body
               }
             end)
       }}
    end
  end

  def parse(_text), do: invalid("document must be text")

  defp read(text) do
    case AL.Syntax.document(text) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, message} -> invalid(message)
    end
  end

  defp render_comment(nil), do: nil

  defp render_comment(comment),
    do:
      comment
      |> String.split("\n")
      |> Enum.map_join("\n", fn
        "" -> "#"
        line -> "# " <> line
      end)

  defp render_header(%__MODULE__{kind: :class} = document) do
    super =
      case document.supers do
        [super] -> super
        supers -> supers
      end

    AL.Syntax.Printer.goal(%AL.Goal.OApply{
      method_id: :defclass,
      args: [document.owner, document.metaclass, super, document.ivars, []]
    }) <> "."
  end

  defp render_header(%__MODULE__{kind: :extension, supers: []}), do: nil

  defp render_header(%__MODULE__{kind: :extension} = document),
    do:
      AL.Syntax.Printer.goal(%AL.Goal.OApply{
        method_id: :extend_class,
        args: [document.owner, document.supers]
      }) <> "."

  defp literal(term), do: AL.Syntax.Printer.term(term)

  defp document(%{kind: :class, name: owner, options: options}, _methods, comment) do
    with :ok <- known_options(options, @class_options),
         {:ok, supers} <- supers(options),
         {:ok, ivars} <- ivars(options),
         :ok <- ground(options) do
      {:ok,
       %__MODULE__{
         kind: :class,
         owner: owner,
         metaclass: Map.get(options, :metaclass, :class),
         supers: supers,
         ivars: ivars,
         comment: comment,
         methods: []
       }}
    end
  end

  defp document(%{kind: :extension, name: owner, options: options}, _methods, comment) do
    with :ok <- known_options(options, [:super]),
         {:ok, supers} <- supers(options),
         :ok <- ground(options) do
      {:ok, extension(owner, supers, comment)}
    end
  end

  defp document(nil, [%{owner: owner} | _], comment), do: {:ok, extension(owner, [], comment)}
  defp document(nil, [], _comment), do: invalid("a definition needs a declaration or a method")

  defp extension(owner, supers, comment),
    do: %__MODULE__{
      kind: :extension,
      owner: owner,
      metaclass: nil,
      supers: supers,
      ivars: [],
      comment: comment,
      methods: []
    }

  defp same_owner(owner, methods) do
    case Enum.find(methods, &(&1.owner != owner)) do
      nil ->
        :ok

      method ->
        invalid("#{literal(method.owner)} >> #{method.selector} is not #{literal(owner)}'s")
    end
  end

  defp known_options(options, known) do
    case Map.keys(options) -- known do
      [] -> :ok
      unknown -> invalid("unknown declaration options #{literal(unknown)}")
    end
  end

  defp supers(options) do
    case Map.get(options, :super, []) do
      supers when is_list(supers) -> {:ok, supers}
      super when is_atom(super) -> {:ok, [super]}
      _other -> invalid("super must be a class or a list of classes")
    end
  end

  defp ivars(options) do
    ivars = Map.get(options, :ivars, [])

    if is_list(ivars) and Enum.all?(ivars, &match?(%{name: _}, &1)),
      do: {:ok, ivars},
      else: invalid("ivars must be a list of maps with a name")
  end

  defp ground(options) do
    if AL.Goal.reduce(options, false, &(&2 or AL.Var.var?(&1))),
      do: invalid("a declaration cannot hold variables"),
      else: :ok
  end

  defp invalid(message), do: {:error, {:invalid_document, message}}
end
