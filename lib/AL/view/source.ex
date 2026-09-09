defmodule AL.Source do
  @moduledoc """
  I render AL goal patterns back into AL source the inverse of `AL.ast_to_pattern/1`.

  Vars are freshened per call scope, so a stored clause carries `{:"$fresh",
  base, scope}` wrappers rather than the bare name it was authored with.
  Printing peels those back to `base` and only appends a numeric suffix when
  two distinct vars land on the same name.

  Goals I don't recognise render as `RAW(<term>)` so there is something to see
  """

  @arith [:+, :-, :*, :/, :**]

  @doc """
  `[name, defmethod-source]` pairs for every method on `class`, decompiled from
  the stored clauses. The store-facing convenience over the pure printers above;
  this is what the GT method-coder view calls over the bridge.
  """
  @spec method_sources(atom(), AL.Branch.t() | atom()) :: [[String.t()]]
  def method_sources(class, branch \\ AL.Branch.head())

  def method_sources(class, id) when is_atom(id),
    do: method_sources(class, %AL.Branch{id: id})

  def method_sources(class, branch) do
    {:atomic, rows} =
      :mnesia.transaction(fn ->
        for {:method, _o, name, id} <- AL.Object.scan_method(class, :"$n", :"$id", branch) do
          source =
            id
            |> AL.Object.scan_oapply(:"$seq", :"$h", :"$b", branch)
            |> Enum.map(fn {:oapply, _id, _seq, h, b} -> defmethod_source(class, name, h, b) end)
            |> Enum.join("\n\n")

          [to_string(name), source]
        end
      end)

    rows
  end

  @doc "GT bridge rows for every open clause on a class."
  @spec method_source_rows(term(), AL.Branch.t() | atom()) :: [
          [String.t() | non_neg_integer() | atom() | term()]
        ]
  def method_source_rows(class, branch \\ AL.Branch.head())

  def method_source_rows(class, id) when is_atom(id),
    do: method_source_rows(class, %AL.Branch{id: id})

  def method_source_rows(class, branch) do
    case :mnesia.transaction(fn ->
           name_pattern = AL.Var.var("source_method_name_#{AL.fresh_scope()}")
           id_pattern = AL.Var.var("source_method_id_#{AL.fresh_scope()}")

           for {:method, ^class, name, _method_seq, _method_t, :open, method_id} <-
                 AL.Object.scan_open_method_versions(class, name_pattern, id_pattern, branch),
               {:oapply, ^method_id, clause_seq, _row_seq, command_t, :open, head, body} <-
                 AL.Object.scan_open_oapply_versions(
                   method_id,
                   AL.Var.var("source_clause_seq_#{AL.fresh_scope()}"),
                   AL.Var.var("source_head_#{AL.fresh_scope()}"),
                   AL.Var.var("source_body_#{AL.fresh_scope()}"),
                   branch
                 ) do
             result = retained_method_source(class, name, head, body, command_t, branch)

             [
               to_string(name),
               clause_seq,
               result.text,
               length(head),
               result.start_line,
               result.provenance,
               result.diagnostic
             ]
           end
         end) do
      {:atomic, rows} -> rows
      {:aborted, _reason} -> []
    end
  end

  @doc "Source rows for one method object's own open clauses, by method identity."
  @spec method_object_source_rows(term(), AL.Branch.t()) :: [
          {:method_source, term(), non_neg_integer(), String.t(), :retained | :decompiled}
        ]
  def method_object_source_rows(method_id, branch \\ AL.Branch.head()) do
    for {:method, class, name, ^method_id} <-
          AL.Object.scan_method(
            AL.Var.var("method_source_class_#{AL.fresh_scope()}"),
            AL.Var.var("method_source_name_#{AL.fresh_scope()}"),
            method_id,
            branch
          ),
        {:oapply, ^method_id, clause_seq, _row_seq, command_t, :open, head, body} <-
          AL.Object.scan_open_oapply_versions(
            method_id,
            AL.Var.var("method_source_seq_#{AL.fresh_scope()}"),
            AL.Var.var("method_source_head_#{AL.fresh_scope()}"),
            AL.Var.var("method_source_body_#{AL.fresh_scope()}"),
            branch
          ) do
      result = retained_method_source(class, name, head, body, command_t, branch)
      {:method_source, method_id, clause_seq, result.text, result.provenance}
    end
  end

  @doc "Print retained (or decompiled) source for every clause of one method."
  @spec print_method(term(), atom(), AL.Branch.t() | atom()) :: :ok
  def print_method(class, name, branch \\ AL.Branch.head()) do
    target = to_string(name)

    class
    |> method_source_rows(branch)
    |> Enum.filter(fn [row_name | _] -> row_name == target end)
    |> Enum.sort_by(fn [_name, seq | _] -> seq end)
    |> Enum.each(fn [_name, _seq, text, _arity, _start, provenance, diagnostic] ->
      if diagnostic, do: IO.puts("# #{provenance}: #{inspect(diagnostic)}")
      IO.puts(text)
      IO.puts("")
    end)
  end

  def transaction_method_rows(tx, branch) do
    commands = AL.Command.commands_for_transaction(tx, branch)
    cutoff = Enum.reduce(commands, -1, fn {:command, t, _, _}, last -> max(t, last) end)

    {_methods, rows} =
      AL.Command.commands_until(cutoff, branch)
      |> Enum.sort_by(fn {:command, t, _, _} -> t end)
      |> Enum.reduce({%{}, []}, fn
        {:command, _, _, {:set_method, {class, name, id}}}, {methods, rows} ->
          {Map.put(methods, id, {class, name}), rows}

        {:command, t, ^tx, {:set_oapply, {id, _seq, head, body}}}, {methods, rows} ->
          case Map.fetch(methods, id) do
            {:ok, {class, name}} ->
              source = retained_method_source(class, name, head, body, t, branch)

              row = [
                "#{inspect(class)} · #{name}",
                t,
                source.text,
                length(head),
                source.start_line
              ]

              {methods, [row | rows]}

            :error ->
              {methods, rows}
          end

        _, acc ->
          acc
      end)

    Enum.reverse(rows)
  end

  @doc "Source for one clause as `defmethod(class, name, head) do body end`."
  @spec defmethod_source(atom(), atom(), term(), [AL.Goal.stored()]) :: String.t()
  def defmethod_source(class, name, head, body) do
    {head, body} = rename({head, body})

    {:defmethod, [], [pat(class), pat(name), pat(head), [do: goals(body)]]}
    |> Macro.to_string()
    |> restore_comments()
  end

  @doc "Source for a body as a do-block."
  @spec body_source([AL.Goal.stored()]) :: String.t()
  def body_source(body) do
    body
    |> rename()
    |> goals()
    |> Macro.to_string()
    |> restore_comments()
  end

  # A comment is not an AST node, so it renders through a placeholder call and
  # becomes a real `#` line here.
  @comment_placeholder :__al_comment__

  defp restore_comments(text) do
    if String.contains?(text, Atom.to_string(@comment_placeholder)) do
      text
      |> String.split("\n")
      |> Enum.map_join("\n", &restore_comment_line/1)
    else
      text
    end
  end

  defp restore_comment_line(line) do
    with %{"indent" => indent, "argument" => argument} <-
           Regex.named_captures(
             ~r/^(?<indent>\s*)#{@comment_placeholder}\((?<argument>.*)\)$/,
             line
           ),
         {:ok, text} when is_binary(text) <- Code.string_to_quoted(argument) do
      indent <> "#" <> text
    else
      _ -> line
    end
  end

  @doc """
  Split a retained clause into its Tonel declaration and verbatim body.

  Scans rather than parses: a decompiled body can contain `RAW(...)` terms that
  are not valid source, and those still have to be sliced.
  """
  @spec split_clause_source(String.t()) :: {:ok, String.t(), String.t()} | :error
  def split_clause_source(text) when is_binary(text) do
    with {:ok, open} <- open_paren(text),
         {:ok, close} <- AL.Source.Scanner.close_index(text, open + 1, ?(, ?)) do
      arguments = binary_part(text, open + 1, close - open - 1)
      {:ok, declaration(arguments), body(text, close + 1)}
    else
      _ -> :error
    end
  end

  def split_clause_source(_text), do: :error

  defp open_paren(text) do
    trimmed = String.trim_leading(text)

    if String.starts_with?(trimmed, "defmethod") do
      case :binary.match(text, "(") do
        {index, _length} -> {:ok, index}
        :nomatch -> :error
      end
    else
      :error
    end
  end

  defp declaration(arguments) do
    case AL.Source.Scanner.top_level_commas(arguments) do
      [first | rest] when rest != [] ->
        arguments
        |> binary_part(first + 1, byte_size(arguments) - first - 1)
        |> String.trim()

      _ ->
        String.trim(arguments)
    end
  end

  defp body(text, index) do
    rest = binary_part(text, index, byte_size(text) - index)
    trimmed = String.trim_trailing(rest)

    with true <- String.ends_with?(trimmed, "end"),
         {do_index, _length} <- :binary.match(trimmed, "do") do
      trimmed
      |> binary_part(do_index + 2, byte_size(trimmed) - do_index - 5)
      |> String.trim_leading("\n")
      |> String.trim_trailing()
    else
      _ -> ""
    end
  end

  @type display_source() :: %{
          text: String.t(),
          start_line: pos_integer(),
          provenance: :retained | :decompiled,
          origin: AL.SourceStore.origin() | nil,
          authored_as: :standalone | :nested | nil,
          diagnostic: term() | nil
        }

  @doc "Return retained source for one open method clause, with a decompiled fallback."
  @spec method_clause_source(
          term(),
          term(),
          term(),
          non_neg_integer(),
          AL.Branch.t()
        ) :: display_source() | {:error, :clause_not_found}
  def method_clause_source(class, name, method_id, clause_seq, branch \\ AL.Branch.head()) do
    {:atomic, result} =
      :mnesia.transaction(fn ->
        case AL.Object.scan_open_oapply_versions(
               method_id,
               clause_seq,
               AL.Var.var("source_head_#{AL.fresh_scope()}"),
               AL.Var.var("source_body_#{AL.fresh_scope()}"),
               branch
             ) do
          [{:oapply, ^method_id, ^clause_seq, _seq, command_t, :open, head, body} | _] ->
            retained_method_source(class, name, head, body, command_t, branch)

          [] ->
            {:error, :clause_not_found}
        end
      end)

    result
  end

  defp retained_method_source(class, name, head, body, command_t, branch) do
    fallback = fn diagnostic ->
      %{
        text: defmethod_source(class, name, head, body),
        start_line: 1,
        provenance: :decompiled,
        origin: nil,
        authored_as: nil,
        diagnostic: diagnostic
      }
    end

    case AL.SourceStore.span(command_t, branch) do
      :absent ->
        fallback.(nil)

      {:source_span, ^command_t, tx_id, :defmethod, range, context} ->
        case AL.SourceStore.text(tx_id, branch) do
          {:source_text, ^tx_id, text, origin} ->
            case AL.Source.Parser.slice(text, range, origin) do
              {:ok, source} ->
                display_range =
                  case Map.get(origin, :range) do
                    %{start: _start, stop: _stop} = container ->
                      AL.Source.Parser.rebase_range(range, container)

                    _ ->
                      range
                  end

                %{
                  text: source,
                  start_line: display_range.start.line,
                  provenance: :retained,
                  origin: origin,
                  authored_as: Map.get(context, :authored_as),
                  diagnostic: nil
                }

              {:error, error} ->
                fallback.({:invalid_source_range, error})
            end

          :absent ->
            fallback.({:missing_source_text, tx_id})
        end

      {:source_span, ^command_t, _tx_id, kind, _range, _context} ->
        fallback.({:source_kind_mismatch, kind})
    end
  end

  @doc "Prepare a parsed program with retry-stable source capture identities."
  @spec prepare(AL.Source.Parser.Result.t(), String.t()) ::
          {:ok, AL.Source.Evaluation.t()} | {:error, AL.Source.Parser.Error.t()}
  def prepare(result, text), do: prepare(result, text, %{kind: :eval_source, label: nil}, text)

  @spec prepare(AL.Source.Parser.Result.t(), String.t(), AL.SourceStore.origin()) ::
          {:ok, AL.Source.Evaluation.t()} | {:error, AL.Source.Parser.Error.t()}
  def prepare(result, text, origin), do: prepare(result, text, origin, text)

  @spec prepare(AL.Source.Parser.Result.t(), String.t(), AL.SourceStore.origin(), String.t()) ::
          {:ok, AL.Source.Evaluation.t()} | {:error, AL.Source.Parser.Error.t()}
  def prepare(result, _text, origin, retained_text) do
    evaluation_ref = make_ref()

    try do
      {program, refs} =
        Enum.reduce(result.captures, {result.program, %{}}, fn capture, {program, refs} ->
          capture_id = {evaluation_ref, capture.ordinal}

          {goal, refs} =
            prepare_capture(Enum.at(program, hd(capture.path)), capture, capture_id, refs)

          {List.replace_at(program, hd(capture.path), goal), refs}
        end)

      {:ok,
       %AL.Source.Evaluation{
         text: retained_text,
         origin: origin,
         program: program,
         refs: refs
       }}
    rescue
      error ->
        {:error,
         %AL.Source.Parser.Error{
           phase: :lowering,
           message: Exception.message(error),
           line: nil,
           column: nil,
           token: nil
         }}
    end
  end

  @doc false
  def enter_scope(state, capture_id, goals) do
    case Map.fetch(state.source_refs, capture_id) do
      {:ok, ref} ->
        context = scope_context(ref, goals)
        refs = Map.put(state.source_refs, capture_id, %AL.Source.Ref{ref | context: context})
        choicepoint = state.active_choicepoint

        %AL{
          state
          | source_refs: refs,
            active_choicepoint: %AL.Choicepoint{
              choicepoint
              | source_scopes: [capture_id | choicepoint.source_scopes],
                goals:
                  goals ++ [%AL.Goal.SourceScopeExit{capture_id: capture_id}] ++ choicepoint.goals
            }
        }

      :error ->
        :mnesia.abort(%AL.Source.ProvenanceError{
          capture_id: capture_id,
          reason: :unknown_capture
        })
    end
  end

  @doc false
  def exit_scope(state, capture_id) do
    case state.active_choicepoint.source_scopes do
      [^capture_id | rest] ->
        %AL{
          state
          | active_choicepoint: %AL.Choicepoint{state.active_choicepoint | source_scopes: rest}
        }

      scopes ->
        :mnesia.abort(%AL.Source.ProvenanceError{
          capture_id: capture_id,
          reason: {:scope_exit_mismatch, scopes}
        })
    end
  end

  @doc false
  def anchor(state, operation, args, command_t) do
    case state.active_choicepoint.source_scopes do
      [capture_id | _] -> anchor_active(state, capture_id, operation, args, command_t)
      [] -> state
    end
  end

  @doc false
  def validate_provenance(state) do
    Enum.each(state.source_refs, fn {capture_id, _ref} ->
      case Map.get(state.source_anchors, capture_id, []) do
        [_command_t] ->
          :ok

        [] ->
          :mnesia.abort(%AL.Source.ProvenanceError{
            capture_id: capture_id,
            reason: :missing_anchor
          })

        anchors ->
          :mnesia.abort(%AL.Source.ProvenanceError{
            capture_id: capture_id,
            reason: {:multiple_anchors, anchors}
          })
      end
    end)

    state
  end

  defp prepare_capture(goal, capture, capture_id, refs) do
    ref = %AL.Source.Ref{
      capture_id: capture_id,
      kind: capture.kind,
      range: capture.range,
      authored_as: capture.authored_as
    }

    refs = Map.put(refs, capture_id, ref)

    {goal, refs} =
      case {capture.kind, goal} do
        {:defclass,
         %AL.Goal.OApply{
           method_id: :defclass,
           args: [name, metaclass, super, ivars, categories, methods, redef]
         } = class_goal} ->
          {tagged_methods, refs} = prepare_nested_methods(methods, capture.children, refs)

          {%AL.Goal.OApply{
             class_goal
             | args: [name, metaclass, super, ivars, categories, tagged_methods, redef]
           }, refs}

        _ ->
          {goal, refs}
      end

    scoped = %AL.Goal.SourceScope{capture_id: capture_id, goals: [goal]}
    {scoped, refs}
  end

  defp prepare_nested_methods(methods, captures, refs) do
    Enum.reduce(captures, {methods, refs}, fn capture, {methods, refs} ->
      capture_id = capture_id_for(capture, refs)
      method_index = List.last(capture.path)
      [method_name, head, body] = Enum.at(methods, method_index)
      tagged = {:al_source_method, capture_id, method_name, head, body}

      ref = %AL.Source.Ref{
        capture_id: capture_id,
        kind: :defmethod,
        range: capture.range,
        authored_as: :nested
      }

      {List.replace_at(methods, method_index, tagged), Map.put(refs, capture_id, ref)}
    end)
  end

  defp capture_id_for(capture, refs) do
    [{evaluation_ref, _ordinal} | _] = Map.keys(refs)
    {evaluation_ref, capture.ordinal}
  end

  defp scope_context(%AL.Source.Ref{kind: :defmethod, authored_as: authored_as}, [
         %AL.Goal.OApply{method_id: :defmethod, args: [class, method | _]}
       ]),
       do: %{class: class, method: method, authored_as: authored_as}

  defp scope_context(%AL.Source.Ref{kind: :defclass, authored_as: authored_as}, [
         %AL.Goal.OApply{method_id: :defclass, args: [class | _]}
       ]),
       do: %{class: class, authored_as: authored_as}

  defp scope_context(ref, goals) do
    :mnesia.abort(%AL.Source.ProvenanceError{
      capture_id: ref.capture_id,
      reason: {:scope_goal_mismatch, goals}
    })
  end

  defp anchor_active(state, capture_id, operation, args, command_t) do
    ref = Map.fetch!(state.source_refs, capture_id)

    if defining_write?(ref, operation, args, state.branch) do
      :ok =
        AL.SourceStore.put_span(
          command_t,
          state.tx_id,
          ref.kind,
          ref.range,
          ref.context,
          state.branch
        )

      %AL{
        state
        | source_anchors:
            Map.update(state.source_anchors, capture_id, [command_t], &[command_t | &1])
      }
    else
      state
    end
  end

  defp defining_write?(
         %AL.Source.Ref{kind: :defclass, context: %{class: class}},
         :set_class,
         [
           object,
           _metaclass
         ],
         _branch
       ),
       do: object == class

  defp defining_write?(
         %AL.Source.Ref{kind: :defmethod, context: %{class: class, method: method}},
         :set_oapply,
         [object, _seq, _head, _body],
         branch
       ) do
    Enum.any?(AL.Object.scan_method(class, method, object, branch), fn
      {:method, ^class, ^method, ^object} -> true
      _row -> false
    end)
  end

  defp defining_write?(_ref, _operation, _args, _branch), do: false

  # --- rename to each var's own authored name, disambiguating collisions ---
  #
  # `freshen/2` (AL.Var) wraps rather than replaces: {:"$fresh", base, scope}
  # nests arbitrarily deep across call scopes, but `base` always bottoms out
  # at the bare `:"$name"` atom the author typed. Peel every wrapper off and
  # reuse that name; only two *different* vars sharing one authored name
  # (freshened copies from different scopes) get a numeric suffix.
  @spec rename(term()) :: term()
  defp rename(term) do
    {map, _seen} =
      term
      |> collect()
      |> Enum.uniq()
      |> Enum.reduce({%{}, %{}}, fn v, {map, seen} ->
        base = base_name(v)
        count = Map.get(seen, base, 0)
        display = if count == 0, do: base, else: "#{base}_#{count + 1}"
        {Map.put(map, v, AL.Var.var(display)), Map.put(seen, base, count + 1)}
      end)

    sub(term, map)
  end

  @spec base_name(AL.Var.t()) :: String.t()
  defp base_name({:"$fresh", base, _scope}), do: base_name(base)

  defp base_name(atom) when is_atom(atom) do
    case Atom.to_string(atom) do
      "$" <> name -> name
      other -> other
    end
  end

  # Vars in first-appearance order (with dups; caller dedups).
  @spec collect(any()) :: [AL.Var.t()]
  defp collect(term) do
    AL.Goal.reduce(term, [], fn leaf, acc -> if AL.Var.var?(leaf), do: [leaf | acc], else: acc end)
    |> Enum.reverse()
  end

  @spec sub(term(), %{optional(atom()) => atom()}) :: term()
  defp sub(term, map), do: AL.Goal.map(term, fn leaf -> Map.get(map, leaf, leaf) end)

  # --- goals -> surface AST ---
  @spec goals([AL.Goal.stored()]) :: Macro.t()
  defp goals([]), do: {:__block__, [], []}
  defp goals([g]), do: goal(g)
  defp goals(gs), do: {:__block__, [], Enum.map(gs, &goal/1)}

  @spec goal(AL.Goal.stored()) :: Macro.t()
  defp goal(:cut), do: {:cut, [], []}
  defp goal(:fail), do: {:fail, [], []}
  defp goal(:pass), do: {:pass, [], []}
  defp goal({:print, p}), do: call(:print, [p])
  defp goal({:not, cond}), do: {:not, [], [Enum.map(cond, &goal/1)]}
  defp goal({:freeze, v, gs}), do: {:freeze, [], [pat(v), Enum.map(gs, &goal/1)]}
  defp goal({:gensym, v}), do: call(:gensym, [v])
  defp goal({:ground, t}), do: call(:ground, [t])
  defp goal({:var, x}), do: call(:var, [x])
  defp goal({:dif, a, b}), do: call(:dif, [a, b])
  defp goal({:in_domain, var, values}), do: call(:in_domain, [var, values])
  defp goal({:label, term}), do: call(:label, [term])
  defp goal({:functor, term, name, args}), do: call(:functor, [term, name, args])
  defp goal({:unify, a, b}), do: call(:unify, [a, b])
  defp goal({:equal, a, b}), do: {:==, [], [pat(a), pat(b)]}

  defp goal({:transaction_source, tx, text, origin}),
    do: call(:vm_transaction_source, [tx, text, origin])

  defp goal({:get_class, o, c}), do: call(:class, [o, c])
  defp goal({:get_super, o, s}), do: call(:super, [o, s])
  defp goal({:set_class, o, c}), do: call(:vm_set_class, [o, c])
  defp goal({:set_super, o, s}), do: call(:vm_set_super, [o, s])
  defp goal({:set_slot, o, k, v}), do: call(:vm_set_slot, [o, k, v])
  defp goal({:get_slot, o, k, v, :aos}), do: call(:vm_get_slot, [o, k, v])
  defp goal({:get_slot, o, k, v, store}), do: call(:vm_get_slot, [o, k, v, store])
  defp goal({:findall, t, cond, r}), do: {:findall, [], [pat(t), Enum.map(cond, &goal/1), pat(r)]}
  defp goal({:retract_class, o, c}), do: call(:vm_retract_class, [o, c])
  defp goal({:retract_super, o, s}), do: call(:vm_retract_super, [o, s])
  defp goal({:retract_slot, o, k}), do: call(:vm_retract_slot, [o, k])
  defp goal({:get_method, o, n, i}), do: call(:vm_method, [o, n, i])
  defp goal({:set_method, o, n, i}), do: call(:vm_set_method, [o, n, i])
  defp goal({:send_async, o, m, a}), do: call(:send_async, [o, m, a])
  defp goal({:send_elixir, pid, msg}), do: call(:send_elixir, [pid, msg])
  defp goal({:retract_oapply, o, head}), do: call(:vm_retract_oapply, [o, head])
  defp goal({:retract_method, o, n, i}), do: call(:vm_retract_method, [o, n, i])
  defp goal({:get_oapply, o, _seq, h, b}), do: call(:vm_clause, [o, h, b])
  defp goal({:set_oapply, o, _seq, h, b}), do: call(:vm_set_oapply, [o, h, b])

  defp goal({:compare, op, a, b}), do: {op, [], [pat(a), pat(b)]}

  defp goal({:oapply, op, args}) when op in @arith and is_list(args),
    do: {op, [], Enum.map(args, &pat/1)}

  defp goal({:oapply, fun, args}) when is_atom(fun) and is_list(args) do
    if AL.Var.var?(fun),
      do: call(:vm_oapply, [fun, args]),
      else: {AL.Lowering.primitive_surface_name(fun), [], Enum.map(args, &pat/1)}
  end

  defp goal({:oapply, fun, args}), do: call(:vm_oapply, [fun, args])

  defp goal({:forall, cond, body}),
    do: {:forall, [], [Enum.map(cond, &goal/1), [do: goals(body)]]}

  defp goal({:or, left, right}),
    do: {:alternative, [], [Enum.map(left, &goal/1), Enum.map(right, &goal/1)]}

  defp goal({:implies, cond, then_, else_}) do
    cond_clause = {:->, [], [[Enum.map(cond, &goal/1)], goals(then_)]}
    else_clause = if else_ == [], do: [], else: [{:->, [], [[:else], goals(else_)]}]
    {:implies, [], [[do: [cond_clause | else_clause]]]}
  end

  defp goal({:call, head, body, args}),
    do:
      {:call, [],
       [pat(head), if(is_list(body), do: Enum.map(body, &goal/1), else: pat(body)), pat(args)]}

  defp goal({:call_next_method, self, args}) when is_list(args),
    do: {:call_next_method, [], [pat(self) | Enum.map(args, &pat/1)]}

  defp goal({:call_next_method, self, args}),
    do: {:call_next_method, [], [pat(self), pat(args)]}

  # A var in method position can't use the `method`, emit explicit send.
  defp goal({:send, r, m, args}) do
    cond do
      not is_list(args) -> {:send, [], [pat(r), pat(m), pat(args)]}
      AL.Var.var?(m) -> {:send, [], [pat(r), pat(m), Enum.map(args, &pat/1)]}
      true -> {m, [], [pat(r) | Enum.map(args, &pat/1)]}
    end
  end

  defp goal({:comment, text}), do: {@comment_placeholder, [], [text]}

  defp goal({:either, left, right}), do: {:or, [], [goal(left), goal(right)]}

  defp goal({:all_dif, vars}), do: call(:all_dif, [vars])

  defp goal({:assert_valid_clause_self, class, head}),
    do: call(:vm_assert_valid_clause_self, [class, head])

  defp goal({:format, control, args}), do: call(:vm_format, [control, args])

  defp goal({:method_source, object, seq, text, provenance}),
    do: call(:vm_method_source, [object, seq, text, provenance])

  defp goal({:slot_at, object, key, value, t}),
    do: call(:vm_slot_at, [object, key, value, t])

  defp goal({:source_scope, capture_id, goals}),
    do: {:vm_source_scope, [], [pat(capture_id), [do: goals(goals)]]}

  defp goal(other), do: {:RAW, [], [Macro.escape(other)]}

  @spec call(atom(), [AL.Var.t()]) :: Macro.t()
  defp call(name, args), do: {name, [], Enum.map(args, &pat/1)}

  # Patterns inside a goal ---> AST ------------
  @spec pat(AL.Var.t()) :: Macro.t()
  defp pat(v) when is_atom(v) do
    s = Atom.to_string(v)

    if String.starts_with?(s, "$"),
      do: {s |> String.trim_leading("$") |> String.to_atom(), [], nil},
      else: v
  end

  defp pat([]), do: []
  defp pat([h | t]) when is_list(t), do: [pat(h) | pat(t)]
  defp pat([h | t]), do: [{:|, [], [pat(h), pat(t)]}]
  defp pat(m) when is_map(m), do: {:%{}, [], Enum.map(m, fn {k, v} -> {pat(k), pat(v)} end)}
  defp pat({:oapply, op, args}) when is_list(args), do: {op, [], Enum.map(args, &pat/1)}
  defp pat({:oapply, op, args}), do: {op, [], [pat(args)]}
  defp pat({a, b}), do: {pat(a), pat(b)}
  defp pat(x), do: x
end
