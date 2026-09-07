defmodule AL.Source.Parser.Error do
  @moduledoc "A structured source parsing, lowering, or range error."

  @type phase() :: :parse | :lowering | :range
  @type t() :: %__MODULE__{
          phase: phase(),
          message: String.t(),
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          token: String.t() | nil
        }

  defexception [:phase, :message, :line, :column, :token]
end

defmodule AL.Source.Parser.Capture do
  @moduledoc "One direct source-bearing definition and its exact input range."

  @type position() :: %{line: pos_integer(), column: pos_integer()}
  @type source_range() :: %{start: position(), stop: position()}
  @type path_component() :: non_neg_integer() | :methods

  @type t() :: %__MODULE__{
          ordinal: non_neg_integer(),
          kind: :defmethod | :defclass,
          path: [path_component()],
          authored_as: :standalone | :nested,
          range: source_range(),
          children: [t()]
        }

  @enforce_keys [:ordinal, :kind, :path, :authored_as, :range]
  defstruct [:ordinal, :kind, :path, :authored_as, :range, children: []]
end

defmodule AL.Source.Parser.Result do
  @moduledoc "A complete lowered source input and its definition capture tree."

  @type t() :: %__MODULE__{
          program: [AL.Goal.t()],
          captures: [AL.Source.Parser.Capture.t()]
        }

  @enforce_keys [:program, :captures]
  defstruct [:program, :captures]
end

defmodule AL.Source.Parser do
  @moduledoc """
  Parses a complete AL source input, lowers it, and extracts exact ranges for
  direct `defmethod` and `defclass` declarations.

  Parsing and lowering are pure. Evaluation remains the responsibility of
  `AL.eval_source/3`.
  """

  alias AL.Source.Parser.{Capture, Error, Result}

  @parse_options [columns: true, token_metadata: true]
  @range_sentinel :__al_source_range_sentinel__

  @spec parse(String.t()) :: {:ok, Result.t()} | {:error, Error.t()}
  def parse(text) when is_binary(text) do
    if String.valid?(text) do
      parse_valid_text(text)
    else
      {:error,
       %Error{
         phase: :parse,
         message: "source must be valid UTF-8",
         line: nil,
         column: nil,
         token: nil
       }}
    end
  end

  def parse(_text) do
    {:error,
     %Error{
       phase: :parse,
       message: "source must be a UTF-8 string",
       line: nil,
       column: nil,
       token: nil
     }}
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

  @doc "Find the authored body range of an `AL.run ... do ... end` call."
  @spec run_range(String.t(), pos_integer(), pos_integer() | nil) ::
          {:ok, Capture.source_range()} | {:error, Error.t()}
  def run_range(text, line, column \\ nil)

  def run_range(text, line, column)
      when is_binary(text) and is_integer(line) and line > 0 and
             (is_integer(column) or is_nil(column)) do
    case parse_with_comments(text, @parse_options) do
      {:ok, ast} -> find_run_range(ast, text, line, column)
      {:error, reason} -> {:error, parse_error(reason)}
    end
  rescue
    exception -> range_error(Exception.message(exception), nil)
  end

  @doc "Rebase a range from an archived source container to its sliced text."
  @spec rebase_range(Capture.source_range(), Capture.source_range()) :: Capture.source_range()
  def rebase_range(
        %{start: %{line: start_line, column: start_column}, stop: stop},
        %{start: %{line: container_line, column: container_column}}
      ) do
    %{
      start:
        rebase_position(
          %{line: start_line, column: start_column},
          container_line,
          container_column
        ),
      stop: rebase_position(stop, container_line, container_column)
    }
  end

  @doc "Slice a range after rebasing it through an origin's source container."
  @spec slice(String.t(), Capture.source_range(), map()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def slice(text, range, origin) when is_binary(text) and is_map(origin) do
    case Map.get(origin, :range) do
      %{start: _start, stop: _stop} = container -> slice(text, rebase_range(range, container))
      _ -> slice(text, range)
    end
  end

  @doc """
  Extract captures and a lowered program from an already-parsed AST, given the
  exact text it was parsed from.

  For an AST a caller parsed itself (for example a macro's own received
  argument, under `columns: true, token_metadata: true`), rather than text
  `parse/1` parsed. Skips the EOF sentinel `parse_valid_text/1` uses: that
  works around the parser omitting `end_of_expression` on the final top-level
  form of a *complete* parse, which does not apply to an AST nested inside a
  larger, unparsed enclosing form.
  """
  @spec capture(Macro.t(), String.t()) :: {:ok, Result.t()} | {:error, Error.t()}
  def capture(ast, text) when is_binary(text) do
    forms = top_level_forms(ast)

    with {:ok, captures, _next_ordinal} <- capture_forms(forms, text, 0, 0, []),
         {:ok, program} <- lower(ast) do
      {:ok, %Result{program: program, captures: captures}}
    end
  end

  @doc "Capture authored method-file shorthand while lowering it with its owner."
  def capture_method(form, text, owner) do
    with {:ok, capture, _} <- capture_form(form, text, [0], :nested, 0),
         {:ok, program} <- lower(qualify_method_form(form, owner)) do
      {:ok, %Result{program: program, captures: [capture]}}
    end
  end

  defp qualify_method_form({:defmethod, meta, args}, owner),
    do: {:defmethod, meta, [owner | args]}

  defp find_run_range(ast, text, line, column) do
    {_ast, result} =
      Macro.prewalk(ast, :not_found, fn node, result ->
        case {node, result} do
          {
            {{:., _dot_metadata, [{:__aliases__, _alias_metadata, [:AL]}, :run]}, metadata,
             _args},
            :not_found
          }
          when is_list(metadata) ->
            if call_at?(metadata, line, column) do
              {node, {:found, metadata}}
            else
              {node, result}
            end

          {{:defpackage, metadata, _args}, :not_found} when is_list(metadata) ->
            if call_at?(metadata, line, column) do
              {node, {:found, metadata}}
            else
              {node, result}
            end

          _ ->
            {node, result}
        end
      end)

    case result do
      {:found, metadata} ->
        with {:ok, do_position} <-
               require_position(metadata_position(metadata[:do]), "run body start is missing"),
             {:ok, start} <- token_stop(text, do_position, "do"),
             {:ok, stop} <-
               require_position(metadata_position(metadata[:end]), "run end is missing"),
             range = %{start: start, stop: stop},
             {:ok, _source} <- slice(text, range) do
          {:ok, range}
        end

      :not_found ->
        range_error("AL.run call is missing from the caller source", %{line: line, column: 1})
    end
  end

  defp call_at?(metadata, line, nil), do: Keyword.get(metadata, :line) == line

  defp call_at?(metadata, line, column),
    do: Keyword.get(metadata, :line) == line and Keyword.get(metadata, :column) == column

  defp rebase_position(%{line: line, column: column}, container_line, container_column) do
    if line == container_line do
      %{line: 1, column: max(column - container_column + 1, 1)}
    else
      %{line: line - container_line + 1, column: column}
    end
  end

  defp parse_valid_text(text) do
    case parse_with_comments(text, @parse_options) do
      {:ok, ast} ->
        with {:ok, metadata_forms} <- metadata_forms(text),
             {:ok, captures, _next_ordinal} <- capture_forms(metadata_forms, text, 0, 0, []),
             {:ok, program} <- lower(ast) do
          {:ok, %Result{program: program, captures: captures}}
        end

      {:error, reason} ->
        {:error, parse_error(reason)}
    end
  end

  # The parser omits end_of_expression on the final form at EOF. Parse a second,
  # validated copy with a following sentinel so every top-level definition has
  # an exclusive end without changing the source that is lowered or sliced.
  defp metadata_forms(text) do
    augmented = text <> "\n:" <> Atom.to_string(@range_sentinel)

    case parse_with_comments(augmented, @parse_options) do
      {:ok, ast} ->
        forms = top_level_forms(ast)

        case List.pop_at(forms, -1) do
          {@range_sentinel, source_forms} -> {:ok, source_forms}
          _other -> range_error("source range sentinel was not parsed as the final form", nil)
        end

      {:error, reason} ->
        error = parse_error(reason)
        {:error, %Error{error | phase: :range}}
    end
  end

  defp lower(ast) do
    lowered = AL.Lowering.ast_to_pattern(ast)

    program =
      case lowered do
        nil -> []
        goals when is_list(goals) -> goals
        goal -> [goal]
      end

    validate_program(program)
  rescue
    exception ->
      {:error,
       %Error{
         phase: :lowering,
         message: Exception.message(exception),
         line: nil,
         column: nil,
         token: nil
       }}
  end

  defp validate_program(program) do
    case Enum.find_index(program, &(not al_goal?(&1))) do
      nil ->
        {:ok, program}

      index ->
        {:error,
         %Error{
           phase: :lowering,
           message: "top-level form #{index} does not lower to an AL goal",
           line: nil,
           column: nil,
           token: nil
         }}
    end
  end

  defp al_goal?(%module{}) when is_atom(module),
    do: module |> Atom.to_string() |> String.starts_with?("Elixir.AL.Goal.")

  defp al_goal?(_term), do: false

  defp top_level_forms({:__block__, _metadata, forms}) when is_list(forms), do: forms
  defp top_level_forms(form), do: [form]

  defp capture_forms([], _text, _form_index, ordinal, captures),
    do: {:ok, Enum.reverse(captures), ordinal}

  defp capture_forms([form | rest], text, form_index, ordinal, captures) do
    with {:ok, capture, next_ordinal} <-
           capture_form(form, text, [form_index], :standalone, ordinal) do
      next_captures = if capture == nil, do: captures, else: [capture | captures]
      capture_forms(rest, text, form_index + 1, next_ordinal, next_captures)
    end
  end

  defp capture_form({:defmethod, metadata, args} = form, text, path, authored_as, ordinal)
       when is_list(metadata) and is_list(args) and
              ((authored_as == :standalone and length(args) in [3, 4]) or
                 (authored_as == :nested and length(args) in [2, 3])) do
    with {:ok, range} <- definition_range(form, metadata, text) do
      {:ok,
       %Capture{
         ordinal: ordinal,
         kind: :defmethod,
         path: path,
         authored_as: authored_as,
         range: range
       }, ordinal + 1}
    end
  end

  defp capture_form(
         {:defclass, metadata, [_name, _options, do_block]} = form,
         text,
         path,
         :standalone,
         ordinal
       )
       when is_list(metadata) do
    with {:ok, range} <- definition_range(form, metadata, text),
         {:ok, children, next_ordinal} <-
           capture_nested_methods(class_body_forms(do_block), text, path, ordinal + 1, 0, []) do
      {:ok,
       %Capture{
         ordinal: ordinal,
         kind: :defclass,
         path: path,
         authored_as: :standalone,
         range: range,
         children: children
       }, next_ordinal}
    end
  end

  defp capture_form(_form, _text, _path, _authored_as, ordinal),
    do: {:ok, nil, ordinal}

  defp capture_nested_methods([], _text, _class_path, ordinal, _method_index, captures),
    do: {:ok, Enum.reverse(captures), ordinal}

  defp capture_nested_methods(
         [form | rest],
         text,
         class_path,
         ordinal,
         method_index,
         captures
       ) do
    path = class_path ++ [:methods, method_index]

    with {:ok, capture, next_ordinal} <- capture_form(form, text, path, :nested, ordinal) do
      next_captures = if capture == nil, do: captures, else: [capture | captures]

      capture_nested_methods(
        rest,
        text,
        class_path,
        next_ordinal,
        method_index + 1,
        next_captures
      )
    end
  end

  defp class_body_forms(do: {:__block__, _metadata, forms}) when is_list(forms), do: forms
  defp class_body_forms(do: nil), do: []
  defp class_body_forms(do: form), do: [form]
  defp class_body_forms(_other), do: []

  defp definition_range(form, metadata, text) do
    start_position = metadata_position(metadata)

    with {:ok, start_position} <- require_position(start_position, "definition start is missing"),
         {:ok, stop_position} <- stop_position(metadata, text, start_position),
         range = %{start: start_position, stop: stop_position},
         {:ok, source} <- slice(text, range),
         :ok <- verify_round_trip(form, source, start_position) do
      {:ok, range}
    end
  end

  defp stop_position(metadata, text, start_position) do
    cond do
      position = metadata_position(metadata[:end]) ->
        token_stop(text, position, "end")

      position = metadata_position(metadata[:closing]) ->
        closing_stop(text, position)

      position = metadata_position(metadata[:end_of_expression]) ->
        expression_stop(text, start_position, position)

      true ->
        range_error("definition end metadata is missing", metadata_position(metadata))
    end
  end

  defp token_stop(text, position, token) do
    stop = advance_column(position, String.length(token))

    case slice(text, %{start: position, stop: stop}) do
      {:ok, ^token} ->
        {:ok, stop}

      {:ok, _other} ->
        range_error("definition end token does not match parser metadata", position)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp closing_stop(text, position) do
    stop = advance_column(position, 1)

    case slice(text, %{start: position, stop: stop}) do
      {:ok, closing} when closing in [")", "]", "}"] ->
        {:ok, stop}

      {:ok, _other} ->
        range_error("definition closing token does not match parser metadata", position)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp expression_stop(text, start_position, stop_position) do
    with {:ok, source} <- slice(text, %{start: start_position, stop: stop_position}) do
      trimmed = String.trim_trailing(source)
      removed_graphemes = String.length(source) - String.length(trimmed)
      {:ok, advance_column(stop_position, -removed_graphemes)}
    end
  end

  @doc """
  Parse AL source with comments spliced into method bodies as inert goals.

  Every caller that lowers AL text must use this rather than
  `Code.string_to_quoted/2`, or a body containing a comment will disagree with
  the range check in `verify_round_trip/3`.
  """
  @spec parse_quoted(String.t(), keyword()) :: {:ok, Macro.t()} | {:error, term()}
  def parse_quoted(text, options),
    do: parse_with_comments(text, Keyword.merge(@parse_options, options))

  # Elixir discards comments before lowering, so a definition could not be
  # regenerated from its stored goals. Capture them and splice them into method
  # bodies as ordinary statements, which lower to inert `AL.Goal.Comment` goals.
  # Only method bodies are spliced: top-level form indices carry capture paths,
  # and class bodies carry method indices, so neither may shift.
  defp parse_with_comments(text, options) do
    case Code.string_to_quoted_with_comments(text, options) do
      {:ok, ast, []} -> {:ok, ast}
      {:ok, ast, comments} -> {:ok, splice_comments(ast, comments)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp splice_comments(ast, comments) do
    Macro.prewalk(ast, fn
      {:defmethod, meta, args} = form when is_list(args) and args != [] ->
        with [{:do, block}] <- List.last(args),
             opening when is_list(opening) <- Keyword.get(meta, :do),
             closing when is_list(closing) <- Keyword.get(meta, :end),
             inner when inner != [] <- enclosed(comments, opening[:line], closing[:line]) do
          {:defmethod, meta, List.replace_at(args, -1, [{:do, splice_block(block, inner)}])}
        else
          _ -> form
        end

      other ->
        other
    end)
  end

  defp enclosed(comments, opening, closing),
    do: Enum.filter(comments, &(&1.line > opening and &1.line < closing))

  defp splice_block(block, comments) do
    statements =
      case block do
        {:__block__, _meta, list} when is_list(list) -> list
        single -> [single]
      end

    {:__block__, [], merge_comments(statements, Enum.sort_by(comments, & &1.line))}
  end

  defp merge_comments([], comments), do: Enum.map(comments, &comment_node/1)
  defp merge_comments(statements, []), do: statements

  defp merge_comments([statement | rest], comments) do
    {leading, trailing} = Enum.split_while(comments, &(&1.line <= statement_line(statement)))
    Enum.map(leading, &comment_node/1) ++ [statement | merge_comments(rest, trailing)]
  end

  defp comment_node(%{text: "#" <> text}), do: {:comment, [], [text]}
  defp comment_node(%{text: text}), do: {:comment, [], [text]}

  defp statement_line({_form, meta, _args}) when is_list(meta), do: Keyword.get(meta, :line, 0)
  defp statement_line(_statement), do: 0

  defp advance_column(%{line: line, column: column}, amount),
    do: %{line: line, column: column + amount}

  defp verify_round_trip(form, source, position) do
    case parse_with_comments(source, @parse_options) do
      {:ok, parsed} ->
        if strip_metadata(parsed) == strip_metadata(form) do
          :ok
        else
          range_error("source range does not round-trip to its definition", position)
        end

      {:error, _reason} ->
        range_error("source range is not a complete definition", position)
    end
  end

  # Comments are dropped on both sides: this check verifies that a captured
  # range round-trips to its definition, and `AL.run` hands us a compile-time
  # AST that never carried comments in the first place.
  defp strip_metadata(ast) do
    Macro.prewalk(ast, fn
      {:__block__, metadata, statements} when is_list(statements) ->
        case Enum.reject(statements, &match?({:comment, _, _}, &1)) do
          [single] -> single
          rest -> {:__block__, metadata, rest}
        end

      node ->
        node
    end)
    |> Macro.prewalk(fn
      {name, metadata, args} when is_atom(name) and is_list(metadata) -> {name, [], args}
      node -> node
    end)
  end

  defp position_offset(text, %{line: line, column: column})
       when is_integer(line) and line > 0 and is_integer(column) and column > 0 do
    starts = line_starts(text)

    case Enum.fetch(starts, line - 1) do
      {:ok, line_start} ->
        next_line_start = Enum.at(starts, line)
        line_stop = if next_line_start == nil, do: byte_size(text), else: next_line_start - 1
        line_text = binary_part(text, line_start, line_stop - line_start)
        graphemes = String.graphemes(line_text)

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

  defp position_offset(_text, position),
    do: range_error("source position is invalid", position)

  defp line_starts(text) do
    [0 | Enum.map(:binary.matches(text, "\n"), fn {offset, 1} -> offset + 1 end)]
  end

  defp require_position(nil, message), do: range_error(message, nil)
  defp require_position(position, _message), do: {:ok, position}

  defp metadata_position(metadata) when is_list(metadata) do
    case {Keyword.get(metadata, :line), Keyword.get(metadata, :column)} do
      {line, column} when is_integer(line) and is_integer(column) ->
        %{line: line, column: column}

      _other ->
        nil
    end
  end

  defp metadata_position(_metadata), do: nil

  defp parse_error({location, description, token}) do
    %Error{
      phase: :parse,
      message: parse_message(description, token),
      line: Keyword.get(location, :line),
      column: Keyword.get(location, :column),
      token: token
    }
  end

  defp parse_message({prefix, suffix}, token),
    do: IO.iodata_to_binary([prefix, token, suffix])

  defp parse_message(description, token),
    do: IO.iodata_to_binary([description, token])

  defp range_error(message, nil) do
    {:error, %Error{phase: :range, message: message, line: nil, column: nil, token: nil}}
  end

  defp range_error(message, %{line: line, column: column}) do
    {:error, %Error{phase: :range, message: message, line: line, column: column, token: nil}}
  end
end
