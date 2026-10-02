defmodule AL.Syntax.Error do
  @moduledoc "A structured source reading, compiling, or range error."

  @type phase() :: :parse | :compile | :range
  @type t() :: %__MODULE__{
          phase: phase(),
          message: String.t(),
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          token: String.t() | nil
        }

  defexception [:phase, :message, :line, :column, :token]
end

defmodule AL.Syntax.Capture do
  @moduledoc "One direct source-bearing definition and its exact input range."

  @type position() :: %{line: pos_integer(), column: pos_integer()}
  @type source_range() :: %{start: position(), stop: position()}

  @type t() :: %__MODULE__{
          ordinal: non_neg_integer(),
          kind: :defmethod | :defclass,
          path: [non_neg_integer()],
          range: source_range()
        }

  @enforce_keys [:ordinal, :kind, :path, :range]
  defstruct [:ordinal, :kind, :path, :range]
end

defmodule AL.Syntax.Result do
  @moduledoc "A complete compiled source input and its definition capture tree."

  @type t() :: %__MODULE__{
          program: [AL.Goal.t()],
          captures: [AL.Syntax.Capture.t()]
        }

  @enforce_keys [:program, :captures]
  defstruct [:program, :captures]
end

defmodule AL.Syntax do
  @moduledoc ~S"""
  Reads AL source and compiles it directly to `AL.Goal` structs, together with
  the exact source ranges of every direct method and class definition.

  A goal is a selector followed by its arguments, `get Self count Count`, the
  first argument being the receiver. Variables are capitalised, atoms are
  lowercase or quoted, `[H . T]` is a list, `#{key => value}` is a map and
  `{goal, ...}` is a block. `@counter #{super => object, ...}.` declares a class,
  `@+counter #{super => [other]}.` adds superclasses to a class owned elsewhere,
  `owner >> selector | Self Arg . Rest | goal, ... .` defines a method clause,
  and every other top-level clause is a comma-separated list of goals ending in
  a full stop.

  The clauses one source gives for an owner and selector are that method's
  definition: the first of them is preceded by `clear_method`, which retracts
  the method's earlier clauses.
  """

  alias AL.Goal
  alias AL.Syntax.{Capture, Error, Result}

  @operator_calls [:=, :==, :<, :>, :<=, :>=, :+, :-, :*, :/, :**, :rem, :or]
  @levels [
    {:right, [";"]},
    {:none, ["->"]}
  ]
  @primitives [
    :map_get,
    :vm_map_put,
    :vm_fresh_id,
    :vm_current_tx,
    :vm_transaction_object,
    :vm_cached_ivar_specs,
    :vm_cached_find_ivar_spec
  ]
  @special [
             :defmethod,
             :clear_method,
             :defclass,
             :extend_class,
             :defprogram,
             :defpackage,
             :findall,
             :forall,
             :not,
             :lambda,
             :spawn,
             :await,
             :freeze,
             :call,
             :call_next_method,
             :comment,
             :cut,
             :fail,
             :pass,
             :vm_source_scope,
             :vm_oapply,
             :vm_set_oapply
           ] ++ @primitives ++ AL.Goal.call_names()
  @argument_starts ["[", "\#{", "{", "(", "^"]

  defguardp goal_body(node)
            when is_tuple(node) and tuple_size(node) == 4 and elem(node, 0) in [:block, :paren]

  @spec reserved?(atom()) :: boolean()
  def reserved?(name), do: name in @special

  @spec primitive?(atom()) :: boolean()
  def primitive?(method_id), do: method_id in @primitives

  @spec parse(String.t(), keyword()) :: {:ok, Result.t()} | {:error, Error.t()}
  def parse(text, options \\ [])

  def parse(text, options) when is_binary(text) do
    with :ok <- valid_text(text),
         {:ok, items} <- read(text),
         items = definitions(items),
         {:ok, program} <- compile(items, Keyword.get(options, :pins, false)) do
      {:ok, %Result{program: program, captures: captures(items)}}
    end
  end

  def parse(_text, _options), do: error(:parse, "source must be a UTF-8 string", nil)

  @spec parse_program(String.t()) ::
          {:ok, %{name: atom(), version: term(), deps: [atom()]}, Result.t()}
          | {:error, Error.t()}
  def parse_program(text) when is_binary(text) do
    with :ok <- valid_text(text),
         {:ok, items} <- read(text) do
      case Enum.reject(items, &comment?/1) do
        [{:call, :defprogram, [{:atom, name, _, _}, {:map, _, _, _} = options], start, _} | rest] ->
          rest = definitions(rest)

          with {:ok, options} <- program_options(options, start),
               {:ok, program} <- compile(rest, false) do
            {:ok,
             %{
               name: name,
               version: Map.get(options, :version, 1),
               deps: Map.get(options, :deps, [])
             }, %Result{program: program, captures: captures(rest)}}
          end

        _ ->
          error(
            :parse,
            "a program file must start with defprogram name #" <> "{version: V, deps: [...]}.",
            nil
          )
      end
    end
  end

  @doc ~S"Read a package manifest: `defpackage name #{...}.` and nothing else."
  @spec package(String.t()) :: {:ok, atom(), map()} | {:error, String.t()}
  def package(text) when is_binary(text) do
    with :ok <- valid_text(text),
         {:ok, items} <- read(text),
         [{:call, :defpackage, [{:atom, name, _, _}, {:map, _, _, _} = options], start, _}] <-
           Enum.reject(items, &comment?/1),
         {:ok, options} <- program_options(options, start) do
      {:ok, name, options}
    else
      {:error, %Error{} = error} -> {:error, Exception.message(error)}
      _ -> {:error, "a manifest is one defpackage name #" <> "{version: V, deps: [...]}."}
    end
  end

  defp program_options(options, start) do
    {:ok, term(options, false)}
  rescue
    exception in ArgumentError -> error(:parse, Exception.message(exception), start)
  end

  @doc """
  Split a retained method definition into its declaration and verbatim body.
  The declaration runs from the selector to the bar closing the head; the body
  is the text after it.
  """
  @spec split_clause(String.t()) :: {:ok, String.t(), String.t()} | :error
  def split_clause(text) when is_binary(text) do
    with {:ok, tokens} <- tokens(text),
         {:ok, {:method, method}, rest} <- method_form(Enum.reject(tokens, &comment?/1)),
         true <- rest == [],
         {:ok, declaration} <-
           slice(text, %{start: start(method.selector), stop: method.head_stop}),
         {:ok, body} <- body_text(text, method) do
      {:ok, declaration, clause_body(body)}
    else
      _ -> :error
    end
  end

  def split_clause(_text), do: :error

  @doc "Method clause source for an owner, a declaration and a body."
  @spec method_text(String.t(), String.t(), String.t()) :: String.t()
  def method_text(owner, declaration, body) do
    header = owner <> " >> " <> declaration

    cond do
      body == "" -> header <> "."
      ends_in_comment?(body) -> header <> "\n" <> body <> "\n."
      true -> header <> "\n" <> body <> "."
    end
  end

  defp ends_in_comment?(text) do
    case tokens(text) do
      {:ok, tokens} -> match?({:comment, _, _, _}, List.last(tokens))
      _ -> false
    end
  end

  @doc """
  Read a definition file: leading `#` comment lines, an optional `@name` class
  or `@+name` extension declaration, then method clauses for that one owner.
  Each method keeps its verbatim declaration and body text.
  """
  @spec document(String.t()) :: {:ok, map()} | {:error, String.t()}
  def document(text) when is_binary(text) do
    with :ok <- valid_text(text),
         {:ok, tokens} <- tokens(text),
         {:ok, items} <- clauses(tokens, []),
         {comments, rest} = Enum.split_while(items, &comment?/1),
         {:ok, header, methods} <- document_header(rest),
         {:ok, methods} <- document_methods(text, methods, []) do
      {:ok, %{comment: document_comment(comments), header: header, methods: methods}}
    else
      {:error, %Error{} = error} -> {:error, Exception.message(error)}
      {:error, message} -> {:error, message}
    end
  end

  defp document_comment([]), do: nil

  defp document_comment(comments),
    do:
      Enum.map_join(comments, "\n", fn {:comment, text, _, _} ->
        String.replace_prefix(text, " ", "")
      end)

  defp document_header([{:class, %{name: {:atom, name, _, _}} = class} | methods]) do
    {:ok,
     %{
       kind: if(class.extend, do: :extension, else: :class),
       name: name,
       options: term(class.options, false)
     }, methods}
  rescue
    exception in ArgumentError -> {:error, Exception.message(exception)}
  end

  defp document_header([{:class, _class} | _methods]),
    do: {:error, "a definition declares a class by its atom name"}

  defp document_header(methods), do: {:ok, nil, methods}

  defp document_methods(_text, [], methods), do: {:ok, Enum.reverse(methods)}

  defp document_methods(
         text,
         [
           {:method, %{owner: {:atom, owner, _, _}, selector: {:atom, selector, _, _}} = method}
           | rest
         ],
         methods
       ) do
    with {:ok, declaration} <-
           slice(text, %{start: start(method.selector), stop: method.head_stop}),
         {:ok, body} <- document_body(text, method) do
      document_methods(text, rest, [
        %{owner: owner, selector: selector, declaration: declaration, body: body} | methods
      ])
    end
  end

  defp document_methods(_text, _items, _methods),
    do: {:error, "a definition holds one declaration and method clauses for one owner"}

  defp document_body(_text, %{body: nil}), do: {:ok, ""}

  defp document_body(text, method) do
    with {:ok, body} <- slice(text, %{start: method.head_stop, stop: method.dot}),
         do: {:ok, clause_body(body)}
  end

  defp method_form(tokens) do
    case owner(tokens) do
      {:ok, owner, selector, rest} -> method(owner, selector, terminated(rest))
      :none -> :error
    end
  end

  defp terminated(tokens) do
    stop = tokens |> List.last() |> then(&(&1 && stop(&1))) || %{line: 1, column: 1}
    tokens ++ [{:punct, ".", stop, stop}]
  end

  defp body_text(_text, %{body: nil}), do: {:ok, ""}
  defp body_text(text, method), do: slice(text, %{start: method.body_start, stop: method.stop})

  defp clause_body(text) do
    case Regex.split(~r/\A[ \t]*\r?\n/, text, parts: 2) do
      ["", body] -> String.trim_trailing(body)
      [body] -> body |> String.trim_leading() |> String.trim_trailing()
    end
  end

  defp read(text) do
    with {:ok, tokens} <- tokens(text), do: clauses(tokens, [])
  end

  defp valid_text(text) do
    if String.valid?(text), do: :ok, else: error(:parse, "source must be valid UTF-8", nil)
  end

  @doc "Returns the exact binary slice selected by a source range."
  @spec slice(String.t(), Capture.source_range()) :: {:ok, String.t()} | {:error, Error.t()}
  def slice(text, %{start: start_position, stop: stop_position}) when is_binary(text) do
    with {:ok, start_offset} <- position_offset(text, start_position),
         {:ok, stop_offset} <- position_offset(text, stop_position),
         true <- start_offset <= stop_offset do
      {:ok, binary_part(text, start_offset, stop_offset - start_offset)}
    else
      false -> range_error("source range stops before it starts", start_position)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def slice(_text, _range),
    do: range_error("source range must contain start and stop positions", nil)

  defp position_offset(text, %{line: line, column: column})
       when is_integer(line) and line > 0 and is_integer(column) and column > 0 do
    starts = line_starts(text)

    case Enum.fetch(starts, line - 1) do
      {:ok, line_start} ->
        next_line_start = Enum.at(starts, line)
        line_stop = if next_line_start == nil, do: byte_size(text), else: next_line_start - 1
        graphemes = text |> binary_part(line_start, line_stop - line_start) |> String.graphemes()

        if column <= length(graphemes) + 1 do
          prefix = graphemes |> Enum.take(column - 1) |> IO.iodata_to_binary()
          {:ok, line_start + byte_size(prefix)}
        else
          range_error("source column is outside the input", %{line: line, column: column})
        end

      :error ->
        range_error("source line is outside the input", %{line: line, column: column})
    end
  end

  defp position_offset(_text, position), do: range_error("source position is invalid", position)

  defp line_starts(text),
    do: [0 | Enum.map(:binary.matches(text, "\n"), fn {offset, 1} -> offset + 1 end)]

  defp range_error(message, nil),
    do: {:error, %Error{phase: :range, message: message, line: nil, column: nil, token: nil}}

  defp range_error(message, %{line: line, column: column}),
    do: {:error, %Error{phase: :range, message: message, line: line, column: column, token: nil}}

  defp tokens(text), do: lex(text, 1, 1, [])

  defp lex(<<>>, _line, _column, tokens), do: {:ok, Enum.reverse(tokens)}
  defp lex(<<"\r\n", rest::binary>>, line, _column, tokens), do: lex(rest, line + 1, 1, tokens)
  defp lex(<<"\n", rest::binary>>, line, _column, tokens), do: lex(rest, line + 1, 1, tokens)

  defp lex(<<c, rest::binary>>, line, column, tokens) when c in [?\s, ?\t, ?\r, ?\v, ?\f],
    do: lex(rest, line, column + 1, tokens)

  defp lex(<<"\#{", rest::binary>>, line, column, tokens),
    do: punct(rest, "\#{", line, column, tokens)

  defp lex(<<"#", rest::binary>>, line, column, tokens) do
    {text, rest} = comment_text(rest, 0)
    stop = column + 1 + String.length(text)
    token = {:comment, text, position(line, column), position(line, stop)}
    lex(rest, line, stop, [token | tokens])
  end

  defp lex(<<quote, rest::binary>>, line, column, tokens) when quote in [?", ?'] do
    start = position(line, column)

    with {:ok, raw, stop_line, stop_column, rest} <-
           quoted(rest, quote, <<quote>>, line, column + 1, start),
         {:ok, value} <- quoted_value(quote, raw, start) do
      kind = if quote == ?", do: :string, else: :atom
      token = {kind, value, start, position(stop_line, stop_column)}
      lex(rest, stop_line, stop_column, [token | tokens])
    end
  end

  defp lex(<<c, _::binary>> = text, line, column, tokens) when c in ?0..?9 do
    {digits, rest} = number_text(text)

    with {:ok, number} <- number(digits, position(line, column)) do
      stop = column + byte_size(digits)
      token = {:number, number, position(line, column), position(line, stop)}
      lex(rest, line, stop, [token | tokens])
    end
  end

  defp lex(<<c, _::binary>> = text, line, column, tokens)
       when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {name, rest} = span(text, &name_char?/1)
    stop = column + byte_size(name)
    kind = if c in ?a..?z, do: :atom, else: :var
    token = {kind, String.to_atom(name), position(line, column), position(line, stop)}
    lex(rest, line, stop, [token | tokens])
  end

  defp lex(<<two::binary-size(2), rest::binary>>, line, column, tokens)
       when two in [">>", "->", "=>"],
       do: punct(rest, two, line, column, tokens)

  defp lex(<<two::binary-size(2), rest::binary>>, line, column, tokens)
       when two in ["==", "<=", ">=", "**"],
       do: operator(rest, two, line, column, tokens)

  defp lex(<<one, rest::binary>>, line, column, tokens) when one in ~c"=<>+-*/",
    do: operator(rest, <<one>>, line, column, tokens)

  defp lex(<<one, rest::binary>>, line, column, tokens) when one in ~c"@()[]{},|.;^",
    do: punct(rest, <<one>>, line, column, tokens)

  defp lex(text, line, column, tokens) do
    {grapheme, rest} = String.next_grapheme(text)

    if String.trim(grapheme) == "",
      do: lex(rest, line, column + 1, tokens),
      else: error(:parse, "unexpected #{grapheme}", position(line, column))
  end

  defp punct(rest, text, line, column, tokens) do
    stop = column + String.length(text)
    lex(rest, line, stop, [{:punct, text, position(line, column), position(line, stop)} | tokens])
  end

  defp operator(rest, text, line, column, tokens) do
    stop = column + byte_size(text)
    token = {:atom, String.to_atom(text), position(line, column), position(line, stop)}
    lex(rest, line, stop, [token | tokens])
  end

  defp comment_text(text, size) do
    case text do
      <<_::binary-size(size), "\r\n", _::binary>> -> split_at(text, size)
      <<_::binary-size(size), "\n", _::binary>> -> split_at(text, size)
      <<_::binary-size(size)>> -> split_at(text, size)
      _ -> comment_text(text, size + 1)
    end
  end

  defp quoted(<<"\\", rest::binary>>, quote, raw, line, column, start) do
    case String.next_grapheme(rest) do
      {escaped, rest} when escaped in ["\n", "\r\n"] ->
        quoted(rest, quote, raw <> "\\" <> escaped, line + 1, 1, start)

      {escaped, rest} ->
        quoted(rest, quote, raw <> "\\" <> escaped, line, column + 2, start)

      nil ->
        error(:parse, "missing closing quote", start)
    end
  end

  defp quoted(<<quote, rest::binary>>, quote, raw, line, column, _start),
    do: {:ok, raw <> <<quote>>, line, column + 1, rest}

  defp quoted(<<"\r\n", rest::binary>>, quote, raw, line, _column, start),
    do: quoted(rest, quote, raw <> "\r\n", line + 1, 1, start)

  defp quoted(<<"\n", rest::binary>>, quote, raw, line, _column, start),
    do: quoted(rest, quote, raw <> "\n", line + 1, 1, start)

  defp quoted(<<>>, _quote, _raw, _line, _column, start),
    do: error(:parse, "missing closing quote", start)

  defp quoted(text, quote, raw, line, column, start) do
    {grapheme, rest} = String.next_grapheme(text)
    quoted(rest, quote, raw <> grapheme, line, column + 1, start)
  end

  defp quoted_value(?", raw, start), do: literal(raw, &is_binary/1, start)
  defp quoted_value(?', raw, start), do: quoted_atom(raw, start)

  defp number_text(text) do
    {integer, rest} = span(text, &(&1 in ?0..?9 or &1 == ?_))

    case rest do
      <<".", d, _::binary>> when d in ?0..?9 ->
        <<".", after_dot::binary>> = rest
        {fraction, rest} = span(after_dot, &(&1 in ?0..?9 or &1 in [?_, ?e, ?E]))
        {integer <> "." <> fraction, rest}

      _ ->
        {integer, rest}
    end
  end

  defp name_char?(c), do: c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_

  defp span(text, keep?), do: split_at(text, span_size(text, keep?, 0))

  defp span_size(text, keep?, size) do
    case text do
      <<_::binary-size(size), c, _::binary>> ->
        if keep?.(c), do: span_size(text, keep?, size + 1), else: size

      _ ->
        size
    end
  end

  defp split_at(text, size),
    do: {binary_part(text, 0, size), binary_part(text, size, byte_size(text) - size)}

  defp number(digits, start) do
    case Code.string_to_quoted(digits) do
      {:ok, number} when is_number(number) -> {:ok, number}
      _ -> error(:parse, "invalid number #{digits}", start)
    end
  end

  defp quoted_atom("'" <> raw, start) do
    body = String.slice(raw, 0..-2//1)
    escaped = body |> String.replace("\\'", "'") |> String.replace("\"", "\\\"")
    literal(":\"" <> escaped <> "\"", &is_atom/1, start)
  end

  defp literal(source, valid?, start) do
    case Code.string_to_quoted(source) do
      {:ok, value} ->
        if valid?.(value),
          do: {:ok, value},
          else: error(:parse, "invalid literal #{source}", start)

      {:error, _reason} ->
        error(:parse, "invalid literal #{source}", start)
    end
  end

  defp clauses([], items), do: {:ok, Enum.reverse(items)}

  defp clauses([{:comment, _, _, _} = comment | rest], items),
    do: clauses(rest, [comment | items])

  defp clauses([{:punct, "@", start, _}, {:atom, :+, _, _} | rest], items) do
    with {:ok, name, rest} <- class_name(rest, start),
         {:ok, {:class, class}, rest} <- class(name, rest, start),
         do: clauses(rest, [{:class, %{class | extend: true}} | items])
  end

  defp clauses([{:punct, "@", start, _} | rest], items) do
    with {:ok, name, rest} <- class_name(rest, start),
         {:ok, class, rest} <- class(name, rest, start),
         do: clauses(rest, [class | items])
  end

  defp clauses(tokens, items) when is_list(tokens) and tokens != [] do
    case owner(tokens) do
      {:ok, owner, selector, rest} ->
        with {:ok, method, rest} <- method(owner, selector, rest),
             do: clauses(rest, [method | items])

      :none ->
        goal_clause(tokens, items)
    end
  end

  defp owner(tokens) do
    with {:ok, owner, [{:punct, ">>", _, _} | rest]} <- argument(tokens),
         {:ok, selector, rest} <- argument(rest) do
      {:ok, owner, selector, rest}
    else
      _ -> :none
    end
  end

  defp goal_clause(tokens, items) do
    with {:ok, goals, rest} <- sequence(tokens, ".") |> at(start_of(tokens)),
         {:ok, rest} <- full_stop(rest, goals) do
      clauses(rest, Enum.reverse(goals) ++ items)
    end
  end

  defp dot([{:punct, ".", start, _} | rest], _items), do: {:ok, start, rest}
  defp dot(tokens, items), do: full_stop(tokens, items)

  defp full_stop([{:punct, ".", _, _} | rest], _items), do: {:ok, rest}
  defp full_stop([token | _], _items), do: unexpected(token, "a full stop")

  defp full_stop([], items) do
    position = items |> Enum.reject(&comment?/1) |> List.last() |> then(&(&1 && stop(&1)))
    error(:parse, "missing full stop", position)
  end

  defp class_name([{kind, _, _, _} = name | rest], _start) when kind in [:atom, :var],
    do: {:ok, name, rest}

  defp class_name([{:punct, "^", start, _}, {kind, name, _, stop} | rest], _start)
       when kind in [:atom, :var],
       do: {:ok, {:pin, name, start, stop}, rest}

  defp class_name([token | _], _start), do: unexpected(token, "a class name after @")
  defp class_name([], start), do: error(:parse, "@ needs a class name", start)

  defp class(name, tokens, start) do
    with {:ok, options, rest} <- argument(tokens),
         [{:punct, ".", _, _} | rest] <- rest do
      {:ok,
       {:class,
        %{name: name, options: options, extend: false, start: start, stop: stop(options)}}, rest}
    else
      {:error, _} = error -> error
      [token | _] -> unexpected(token, "a full stop after the class options")
      [] -> error(:parse, "a class needs a map of options and a full stop", start)
    end
  end

  defp method(owner, selector, tokens) do
    with {:ok, head_start, rest} <- head_open(tokens, selector),
         {:ok, arguments, tail, rest} <- head(rest, []),
         {:ok, head_stop, rest} <- head_close(rest, selector) do
      base = %{
        owner: owner,
        selector: selector,
        arguments: arguments,
        tail: tail,
        head_start: head_start,
        head_stop: head_stop,
        start: start(owner)
      }

      case rest do
        [{:punct, ".", dot, _} | rest] ->
          {:ok,
           {:method, Map.merge(base, %{body: nil, body_start: nil, stop: head_stop, dot: dot})},
           rest}

        rest ->
          with {:ok, body, rest} <- sequence(rest, ".") |> at(head_stop),
               {:ok, dot, rest} <- dot(rest, body) do
            stop =
              body |> Enum.reject(&comment?/1) |> List.last() |> then(&(&1 && stop(&1))) ||
                head_stop

            {:ok,
             {:method,
              Map.merge(base, %{body: body, body_start: head_stop, stop: stop, dot: dot})}, rest}
          end
      end
    end
  end

  defp head_open([{:punct, "|", start, _} | rest], _selector), do: {:ok, start, rest}
  defp head_open([token | _], _selector), do: unexpected(token, "| to open the method head")
  defp head_open([], selector), do: error(:parse, "a method needs a | head |", stop(selector))

  defp head_close([{:punct, "|", _, stop} | rest], _selector), do: {:ok, stop, rest}
  defp head_close([token | _], _selector), do: unexpected(token, "| to close the method head")

  defp head_close([], selector),
    do: error(:parse, "missing | after the method head", stop(selector))

  defp head([{:punct, ".", _, _} | rest], arguments) do
    with {:ok, tail, rest} <- argument(rest), do: {:ok, Enum.reverse(arguments), tail, rest}
  end

  defp head(tokens, arguments) do
    if argument_start?(tokens) do
      with {:ok, argument, rest} <- argument(tokens), do: head(rest, [argument | arguments])
    else
      {:ok, Enum.reverse(arguments), nil, tokens}
    end
  end

  defp at({:error, %Error{line: nil} = error}, %{line: line, column: column}),
    do: {:error, %{error | line: line, column: column}}

  defp at(result, _position), do: result

  defp start_of([token | _]), do: start(token)

  defp sequence(tokens, closer), do: sequence(tokens, closer, [], false)

  defp sequence(tokens, closer, items, separated?) do
    case tokens do
      [{:comment, _, _, _} = comment | rest] ->
        sequence(rest, closer, [comment | items], separated?)

      [{:punct, ^closer, _, _} | _] ->
        {:ok, Enum.reverse(items), tokens}

      [{:punct, ",", _, _} | rest] when separated? ->
        sequence(rest, closer, items, false)

      [token | _] when separated? ->
        unexpected(token, "a comma or #{describe_closer(closer)}")

      [] ->
        error(:parse, "missing #{describe_closer(closer)}", nil)

      tokens ->
        with {:ok, item, rest} <- expression(tokens) do
          sequence(rest, closer, [item | items], true)
        end
    end
  end

  defp describe_closer("."), do: "a full stop"
  defp describe_closer(closer), do: closer

  defp expression(tokens), do: operators(tokens, @levels)

  defp operators(tokens, []), do: unary(tokens)

  defp operators(tokens, [_ | tighter] = levels) do
    with {:ok, left, rest} <- operators(tokens, tighter), do: operator_rest(left, rest, levels)
  end

  defp operator_rest(left, tokens, [{associativity, operators} | tighter] = levels) do
    case operator(tokens, operators) do
      {:ok, op, rest} ->
        right_levels = if associativity == :right, do: levels, else: tighter

        with {:ok, right, rest} <- operators(rest, right_levels),
             do: {:ok, {:binary, op, left, right, start(left), stop(right)}, rest}

      :none ->
        {:ok, left, tokens}
    end
  end

  defp operator([{:punct, op, _, _} | rest], operators) do
    if op in operators,
      do: {:ok, if(is_atom(op), do: op, else: String.to_atom(op)), rest},
      else: :none
  end

  defp operator(_tokens, _operators), do: :none

  defp unary([{:atom, :-, minus, _}, {:number, number, number_start, stop} | rest])
       when minus.line == number_start.line and minus.column + 1 == number_start.column,
       do: {:ok, {:literal, -number, minus, stop}, rest}

  defp unary([{:atom, name, start, stop} | rest] = tokens) do
    if argument_start?(rest) do
      call_arguments(name, start, stop, rest, [])
    else
      argument(tokens)
    end
  end

  defp unary(tokens), do: argument(tokens)

  defp call_arguments(name, start, stop, tokens, arguments) do
    if argument_start?(tokens) do
      with {:ok, argument, rest} <- argument(tokens),
           do: call_arguments(name, start, stop(argument), rest, [argument | arguments])
    else
      {:ok, {:call, name, Enum.reverse(arguments), start, stop}, tokens}
    end
  end

  defp argument_start?([{kind, _, _, _} | _]) when kind in [:var, :atom, :number, :string],
    do: true

  defp argument_start?([{:punct, punct, _, _} | _]) when punct in @argument_starts, do: true

  defp argument_start?(_tokens), do: false

  defp argument([{:atom, :-, minus, _}, {:number, number, number_start, stop} | rest])
       when minus.line == number_start.line and minus.column + 1 == number_start.column,
       do: {:ok, {:literal, -number, minus, stop}, rest}

  defp argument([{:number, value, start, stop} | rest]),
    do: {:ok, {:literal, value, start, stop}, rest}

  defp argument([{:string, value, start, stop} | rest]),
    do: {:ok, {:literal, value, start, stop}, rest}

  defp argument([{:var, name, start, stop} | rest]), do: {:ok, {:var, name, start, stop}, rest}
  defp argument([{:atom, name, start, stop} | rest]), do: {:ok, {:atom, name, start, stop}, rest}

  defp argument([{:punct, "^", start, _}, {kind, name, _, stop} | rest])
       when kind in [:atom, :var],
       do: {:ok, {:pin, name, start, stop}, rest}

  defp argument([{:punct, "[", start, _} | rest]) do
    with {:ok, items, rest} <- rest |> list_items([]) |> at(start),
         [{:punct, "]", _, stop} | rest] <- rest do
      {:ok, {:list, items, start, stop}, rest}
    else
      {:error, _} = error -> error
      _ -> error(:parse, "missing ]", start)
    end
  end

  defp argument([{:punct, "\#{", start, _} | rest]) do
    with {:ok, entries, rest} <- rest |> map_entries([]) |> at(start),
         [{:punct, "}", _, stop} | rest] <- rest do
      {:ok, {:map, entries, start, stop}, rest}
    else
      {:error, _} = error -> error
      _ -> error(:parse, "missing }", start)
    end
  end

  defp argument([{:punct, "{", start, _} | rest]) do
    with {:ok, items, rest} <- rest |> sequence("}") |> at(start),
         [{:punct, "}", _, stop} | rest] <- rest do
      {:ok, {:block, items, start, stop}, rest}
    end
  end

  defp argument([{:punct, "(", start, _} | rest]) do
    with {:ok, inner, rest} <- rest |> expression() |> at(start),
         [{:punct, ")", _, stop} | rest] <- rest do
      {:ok, {:paren, inner, start, stop}, rest}
    else
      {:error, _} = error -> error
      [token | _] -> unexpected(token, ")")
      [] -> error(:parse, "missing )", start)
    end
  end

  defp argument([token | _]), do: unexpected(token, "a term")
  defp argument([]), do: error(:parse, "unexpected end of input", nil)

  defp list_items([{:punct, "]", _, _} | _] = tokens, items),
    do: {:ok, Enum.reverse(items), tokens}

  defp list_items(tokens, items) do
    with {:ok, item, rest} <- expression(tokens) do
      case rest do
        [{:punct, ",", _, _} | rest] ->
          list_items(rest, [item | items])

        [{:punct, ".", _, _} | rest] ->
          with {:ok, tail, rest} <- expression(rest),
               do: {:ok, Enum.reverse([{:tail, tail} | [item | items]]), rest}

        rest ->
          {:ok, Enum.reverse([item | items]), rest}
      end
    end
  end

  defp map_entries([{:punct, "}", _, _} | _] = tokens, entries),
    do: {:ok, Enum.reverse(entries), tokens}

  defp map_entries(tokens, entries) do
    with {:ok, key, rest} <- expression(tokens),
         [{:punct, "=>", _, _} | rest] <- rest,
         {:ok, value, rest} <- expression(rest) do
      map_next(rest, [{key, value} | entries])
    else
      {:error, _} = error -> error
      [token | _] -> unexpected(token, "=>")
      [] -> error(:parse, "missing }", nil)
    end
  end

  defp map_next([{:punct, ",", _, _} | rest], entries), do: map_entries(rest, entries)
  defp map_next(rest, entries), do: {:ok, Enum.reverse(entries), rest}

  defp unexpected({_kind, value, start, _stop}, expected),
    do: error(:parse, "expected #{expected} but found #{inspect_token(value)}", start)

  defp inspect_token(value) when is_binary(value), do: value
  defp inspect_token(value), do: inspect(value)

  defp definitions(items) do
    {items, _defined} =
      Enum.flat_map_reduce(items, MapSet.new(), fn
        {:method, %{owner: owner, selector: selector}} = method, defined when owner != nil ->
          key = {definition_key(owner), definition_key(selector)}

          if MapSet.member?(defined, key),
            do: {[method], defined},
            else: {[{:clear, owner, selector}, method], MapSet.put(defined, key)}

        item, defined ->
          {[item], defined}
      end)

    items
  end

  defp definition_key({kind, name, _start, _stop}), do: {kind, name}

  defp compile(items, pins) do
    {items, _count} = items |> Enum.reject(&comment?/1) |> number_anonymous(0)
    {:ok, Enum.map(items, &item(&1, pins))}
  rescue
    exception in ArgumentError -> error(:compile, Exception.message(exception), nil)
  end

  defp number_anonymous({:var, :_, start, stop}, count),
    do: {{:var, String.to_atom("_@#{count + 1}"), start, stop}, count + 1}

  defp number_anonymous(list, count) when is_list(list),
    do: Enum.map_reduce(list, count, &number_anonymous/2)

  defp number_anonymous(map, count) when is_map(map) and not is_struct(map) do
    {pairs, count} =
      Enum.map_reduce(map, count, fn {key, value}, count ->
        {value, count} = number_anonymous(value, count)
        {{key, value}, count}
      end)

    {Map.new(pairs), count}
  end

  defp number_anonymous(tuple, count) when is_tuple(tuple) do
    {items, count} = tuple |> Tuple.to_list() |> number_anonymous(count)
    {List.to_tuple(items), count}
  end

  defp number_anonymous(other, count), do: {other, count}

  defp item({:clear, owner, selector}, pins),
    do: %Goal.OApply{method_id: :clear_method, args: [term(owner, pins), term(selector, pins)]}

  defp item({:method, method}, pins) do
    %Goal.OApply{
      method_id: :defmethod,
      args: [
        term(method.owner, pins),
        term(method.selector, pins),
        head_term(method, pins),
        body(method.body, pins)
      ]
    }
  end

  defp item({:class, %{extend: true} = class}, pins) do
    options =
      case class.options do
        {:map, _, _, _} = options -> term(options, pins)
        other -> raise ArgumentError, "@+ at #{describe(start(other))} needs a map of options"
      end

    supers =
      case Map.fetch(options, :super) do
        {:ok, supers} when is_list(supers) -> supers
        {:ok, super} -> [super]
        :error -> raise ArgumentError, "@+ at #{describe(class.start)} needs a super: option"
      end

    %Goal.OApply{method_id: :extend_class, args: [term(class.name, pins), supers]}
  end

  defp item({:class, class}, pins) do
    options =
      case class.options do
        {:map, _, _, _} = options ->
          term(options, pins)

        other ->
          raise ArgumentError, "a class at #{describe(start(other))} needs a map of options"
      end

    %Goal.OApply{
      method_id: :defclass,
      args: [
        term(class.name, pins),
        Map.get(options, :metaclass, :class),
        Map.get(options, :super) ||
          raise(ArgumentError, "a class at #{describe(class.start)} needs a super: option"),
        Map.get(options, :ivars, []),
        Map.get(options, :categories, [])
      ]
    }
  end

  defp item(node, pins), do: goal(node, pins)

  defp head_term(method, pins) do
    arguments = Enum.map(method.arguments, &term(&1, pins))

    case method.tail do
      nil -> arguments
      tail -> arguments ++ term(tail, pins)
    end
  end

  defp goal({:binary, :";", {:binary, :->, condition, then, _, _}, otherwise, _, _}, pins),
    do: %Goal.Implies{
      condition: goals(condition, pins),
      then: goals(then, pins),
      otherwise: goals(otherwise, pins)
    }

  defp goal({:binary, :";", left, right, _, _}, pins),
    do: %Goal.Or{or: goals(left, pins), then: goals(right, pins)}

  defp goal({:binary, :->, condition, then, _, _}, pins),
    do: %Goal.Implies{
      condition: goals(condition, pins),
      then: goals(then, pins),
      otherwise: [%Goal.Fail{}]
    }

  defp goal({:paren, inner, _, _}, pins), do: goal(inner, pins)
  defp goal({:atom, :cut, _, _}, _pins), do: %Goal.Cut{}
  defp goal({:atom, :fail, _, _}, _pins), do: %Goal.Fail{}
  defp goal({:atom, :pass, _, _}, _pins), do: %Goal.Pass{}
  defp goal({:atom, name, _, _}, _pins), do: %Goal.OApply{method_id: name, args: []}
  defp goal({:call, name, arguments, start, _}, pins), do: call(name, arguments, start, pins)
  defp goal({:var, _, _, _} = variable, pins), do: term(variable, pins)

  defp goal({:block, _, start, _}, _pins),
    do: raise(ArgumentError, "a block at #{describe(start)} is not a goal on its own")

  defp goal(node, _pins), do: raise(ArgumentError, "expected a goal at #{describe(start(node))}")

  defp call(:defmethod, [class, selector, head, block], _start, pins)
       when goal_body(block),
       do: %Goal.OApply{
         method_id: :defmethod,
         args: [term(class, pins), term(selector, pins), term(head, pins), goals(block, pins)]
       }

  defp call(:clear_method, [owner, selector], _start, pins),
    do: %Goal.OApply{method_id: :clear_method, args: [term(owner, pins), term(selector, pins)]}

  defp call(:findall, [template, result, block], _start, pins)
       when goal_body(block),
       do: %Goal.Findall{
         template: term(template, pins),
         condition: goals(block, pins),
         result: term(result, pins)
       }

  defp call(:forall, [condition, block], _start, pins)
       when goal_body(block),
       do: %Goal.Forall{condition: goals(condition, pins), body: goals(block, pins)}

  defp call(:not, [condition], _start, pins), do: %Goal.Not{condition: goals(condition, pins)}

  defp call(:lambda, [arguments, method, block], _start, pins)
       when goal_body(block),
       do: %Goal.Send{
         object: term(arguments, pins),
         method: :lambda,
         args: [term(method, pins), goals(block, pins)]
       }

  defp call(:spawn, [block], start, pins)
       when goal_body(block) do
    case goals(block, pins) do
      [] -> raise ArgumentError, "spawn at #{describe(start)} requires at least one goal"
      goals -> %Goal.OApply{method_id: :spawn_transaction, args: [goals]}
    end
  end

  defp call(:await, [effect, {:list, _, _, _} = head, block], start, pins)
       when goal_body(block) do
    case goals(block, pins) do
      [] ->
        raise ArgumentError, "await at #{describe(start)} requires at least one goal"

      goals ->
        %Goal.OApply{
          method_id: :await_effect,
          args: [term(effect, pins), term(head, pins), goals]
        }
    end
  end

  defp call(:vm_source_scope, [capture_id, block], _start, pins)
       when goal_body(block),
       do: %Goal.SourceScope{capture_id: term(capture_id, pins), goals: goals(block, pins)}

  defp call(:freeze, [variable, goals], _start, pins),
    do: %Goal.Freeze{var: term(variable, pins), goals: goals(goals, pins)}

  defp call(:call, [head, body, args], _start, pins),
    do: %Goal.Call{head: term(head, pins), body: goals(body, pins), args: term(args, pins)}

  defp call(:vm_set_oapply, [object, head, body], _start, pins),
    do: %Goal.SetOapply{
      object: term(object, pins),
      seq: :next,
      head: term(head, pins),
      body: goals(body, pins)
    }

  defp call(:vm_set_oapply, [object, seq, head, body], _start, pins),
    do: %Goal.SetOapply{
      object: term(object, pins),
      seq: term(seq, pins),
      head: term(head, pins),
      body: goals(body, pins)
    }

  defp call(name, arguments, _start, pins),
    do: simple_call(name, Enum.map(arguments, &term(&1, pins)))

  defp simple_call(name, args) do
    case {name, args} do
      {:comment, [text]} when is_binary(text) ->
        %Goal.Comment{text: text}

      {:vm_oapply, [method_id, args]} ->
        %Goal.OApply{method_id: method_id, args: args}

      {:call_next_method, [self | args]} ->
        %Goal.CallNextMethod{self: self, args: args}

      {name, args} when name in @primitives ->
        %Goal.OApply{method_id: name, args: args}

      {name, args} when name in @operator_calls ->
        Goal.from_call_form(name, args)

      {name, args} ->
        Goal.from_call(name, args) || send_call(name, args)
    end
  end

  defp send_call(name, [object | args]), do: %Goal.Send{object: object, method: name, args: args}
  defp send_call(name, []), do: %Goal.OApply{method_id: name, args: []}

  defp body(nil, _pins), do: []

  defp body(items, pins) when is_list(items) do
    Enum.map(items, fn
      {:comment, text, _, _} -> %Goal.Comment{text: text}
      item -> goal(item, pins)
    end)
  end

  defp body({:block, items, _, _}, pins), do: body(items, pins)

  defp goals({:block, _, _, _} = block, pins), do: body(block, pins)
  defp goals({:var, _, _, _} = variable, pins), do: term(variable, pins)
  defp goals({:pin, _, _, _} = pin, pins), do: term(pin, pins)
  defp goals({:paren, inner, _, _}, pins), do: goals(inner, pins)
  defp goals(node, pins), do: [goal(node, pins)]

  defp term({:literal, value, _, _}, _pins), do: value
  defp term({:atom, value, _, _}, _pins), do: value
  defp term({:var, name, _, _}, _pins), do: AL.Var.var(name)

  defp term({:paren, {:atom, name, _, _}, _, _}, _pins),
    do: %Goal.OApply{method_id: name, args: []}

  defp term({:paren, inner, _, _}, pins), do: term(inner, pins)
  defp term({:block, _, _, _} = block, pins), do: body(block, pins)

  defp term({:list, items, _, _}, pins) do
    case Enum.split(items, -1) do
      {init, [{:tail, tail}]} -> Enum.map(init, &term(&1, pins)) ++ term(tail, pins)
      _ -> Enum.map(items, &term(&1, pins))
    end
  end

  defp term({:map, entries, _, _}, pins),
    do: Map.new(entries, fn {key, value} -> {term(key, pins), term(value, pins)} end)

  defp term({:binary, op, _, _, _, _} = node, pins) when op in [:";", :->],
    do: goal(node, pins)

  defp term({:call, _, _, _, _} = node, pins), do: goal(node, pins)

  defp term({:pin, name, start, _}, pins) do
    if pins,
      do: {:unquote, [], [{name, [], nil}]},
      else: raise(ArgumentError, "^#{name} at #{describe(start)} is only valid in ~AL")
  end

  defp captures(items) do
    {captures, _ordinal} =
      items
      |> Enum.reject(&comment?/1)
      |> Enum.with_index()
      |> Enum.flat_map_reduce(0, fn {item, index}, ordinal -> capture(item, index, ordinal) end)

    captures
  end

  defp capture({:method, method}, index, ordinal),
    do: {[capture(:defmethod, index, method.start, method.stop, ordinal)], ordinal + 1}

  defp capture({:class, %{extend: true}}, _index, ordinal), do: {[], ordinal}

  defp capture({:class, class}, index, ordinal),
    do: {[capture(:defclass, index, class.start, class.stop, ordinal)], ordinal + 1}

  defp capture(_item, _index, ordinal), do: {[], ordinal}

  defp capture(kind, index, start, stop, ordinal),
    do: %Capture{ordinal: ordinal, kind: kind, path: [index], range: %{start: start, stop: stop}}

  defp start({:method, %{start: start}}), do: start
  defp start({:class, %{start: start}}), do: start
  defp start({_kind, _a, _b, _c, start, _stop}), do: start
  defp start({_kind, _a, _b, start, _stop}), do: start
  defp start({_kind, _a, start, _stop}), do: start
  defp start({:tail, node}), do: start(node)

  defp stop({:method, %{stop: stop}}), do: stop
  defp stop({:class, %{stop: stop}}), do: stop
  defp stop({_kind, _a, _b, _c, _start, stop}), do: stop
  defp stop({_kind, _a, _b, _start, stop}), do: stop
  defp stop({_kind, _a, _start, stop}), do: stop
  defp stop({:tail, node}), do: stop(node)

  defp comment?({:comment, _, _, _}), do: true
  defp comment?(_item), do: false

  defp position(line, column), do: %{line: line, column: column}

  defp describe(nil), do: "the input"
  defp describe(%{line: line, column: column}), do: "#{line}:#{column}"

  defp error(phase, message, nil),
    do: {:error, %Error{phase: phase, message: message, line: nil, column: nil, token: nil}}

  defp error(phase, message, %{line: line, column: column}),
    do: {:error, %Error{phase: phase, message: message, line: line, column: column, token: nil}}
end
