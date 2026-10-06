defmodule AL.Source do
  @moduledoc """
  I render stored AL goals back into AL source, the inverse of `AL.Syntax`.

  Vars are freshened per call scope, so a stored clause carries `{:"$fresh",
  base, scope}` wrappers rather than the bare name it was authored with.
  Printing peels those back to `base` and only appends a numeric suffix when
  two distinct vars land on the same name.
  """

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

  @doc "Source for one clause as `class >> name | Head | Body`."
  @spec defmethod_source(term(), term(), term(), [AL.Goal.stored()]) :: String.t()
  def defmethod_source(class, name, head, body) do
    {head, body} = rename({head, body})
    AL.Syntax.Printer.defmethod(class, name, head, body)
  end

  @doc "Source for a body as AL goals, one per line."
  @spec body_source([AL.Goal.stored()]) :: String.t()
  def body_source(body), do: body |> rename() |> AL.Syntax.Printer.body()

  @doc "Split a retained clause into its declaration and verbatim body."
  @spec split_clause_source(String.t()) :: {:ok, String.t(), String.t()} | :error
  defdelegate split_clause_source(text), to: AL.Syntax, as: :split_clause

  @type display_source() :: %{
          text: String.t(),
          start_line: pos_integer(),
          provenance: :retained | :decompiled,
          origin: AL.SourceStore.origin() | nil,
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
        method_clause_source_in_transaction(class, name, method_id, clause_seq, branch)
      end)

    result
  end

  @doc false
  def method_clause_source_in_transaction(class, name, method_id, clause_seq, branch) do
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
  end

  defp retained_method_source(class, name, head, body, command_t, branch) do
    fallback = fn diagnostic ->
      %{
        text: defmethod_source(class, name, head, body),
        start_line: 1,
        provenance: :decompiled,
        origin: nil,
        diagnostic: diagnostic
      }
    end

    case AL.SourceStore.span(command_t, branch) do
      :absent ->
        fallback.(nil)

      {:source_span, ^command_t, tx_id, :defmethod, range, _context} ->
        case AL.SourceStore.text(tx_id, branch) do
          {:source_text, ^tx_id, text, origin} ->
            case AL.Syntax.slice(text, range) do
              {:ok, source} ->
                %{
                  text: source,
                  start_line: range.start.line,
                  provenance: :retained,
                  origin: origin,
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
  @spec prepare(AL.Syntax.Result.t(), AL.SourceStore.origin(), String.t()) ::
          {:ok, AL.Source.Evaluation.t()} | {:error, AL.Syntax.Error.t()}
  def prepare(result, origin, text) do
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
         text: text,
         origin: origin,
         program: program,
         refs: refs
       }}
    rescue
      error ->
        {:error,
         %AL.Syntax.Error{
           phase: :compile,
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
              | source_scopes: [capture_id | choicepoint.source_scopes]
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
    ref = %AL.Source.Ref{capture_id: capture_id, kind: capture.kind, range: capture.range}

    refs = Map.put(refs, capture_id, ref)

    scoped = %AL.Goal.SourceScope{capture_id: capture_id, goals: [goal]}
    {scoped, refs}
  end

  defp scope_context(%AL.Source.Ref{kind: :defmethod}, [
         %AL.Goal.OApply{method_id: :defmethod, args: [class, method | _]}
       ]),
       do: %{class: class, method: method}

  defp scope_context(%AL.Source.Ref{kind: :defclass}, [
         %AL.Goal.OApply{method_id: :defclass, args: [class | _]}
       ]),
       do: %{class: class}

  defp scope_context(%AL.Source.Ref{kind: :defmethod}, [
         %AL.Goal.Compound{name: :defmethod, args: [class, method | _]}
       ]),
       do: %{class: class, method: method}

  defp scope_context(%AL.Source.Ref{kind: :defclass}, [
         %AL.Goal.Compound{name: :defclass, args: [class | _]}
       ]),
       do: %{class: class}

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
end
