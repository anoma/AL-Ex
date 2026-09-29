defmodule AL.Syntax.Printer do
  @moduledoc """
  Prints `AL.Goal` structs and AL terms as AL source, the inverse of
  `AL.Syntax`. Reading printed text compiles back to the same goals.
  """

  alias AL.Goal
  alias AL.Syntax

  @semi 1
  @arrow 2
  @either 3
  @comparison 4
  @additive 5
  @multiplicative 6
  @power 7
  @unary 8
  @call 8
  @primary 9

  @spec defmethod(term(), term(), term(), [term()]) :: String.t()
  def defmethod(class, selector, head, body), do: method(class, selector, head, body, "")

  @spec program([term()]) :: String.t()
  def program(goals) do
    goals
    |> Enum.map(&load/1)
    |> clauses(MapSet.new())
    |> Enum.chunk_by(&elem(&1, 0))
    |> Enum.map_join("\n\n", fn [{kind, _} | _] = chunk ->
      separator = if kind == :definition, do: "\n\n", else: "\n"
      Enum.map_join(chunk, separator, &elem(&1, 1))
    end)
  end

  defp clauses([], _defined), do: []

  defp clauses(
         [
           %Goal.OApply{method_id: :clear_method, args: [owner, selector]} = clear,
           %Goal.OApply{method_id: :defmethod, args: [owner, selector, _, body]} = method | rest
         ],
         defined
       )
       when is_list(body) do
    if MapSet.member?(defined, {owner, selector}),
      do: [goal_clause(clear) | clauses([method | rest], defined)],
      else: clauses([method | rest], MapSet.put(defined, {owner, selector}))
  end

  defp clauses(
         [%Goal.OApply{method_id: :defmethod, args: [owner, selector, head, body]} = goal | rest],
         defined
       )
       when is_list(body) do
    clause =
      if MapSet.member?(defined, {owner, selector}),
        do: {:definition, method(owner, selector, head, body, "") <> full_stop(body)},
        else: goal_clause(goal)

    [clause | clauses(rest, defined)]
  end

  defp clauses([%Goal.OApply{method_id: id} = goal | rest], defined)
       when id in [:defclass, :extend_class],
       do: [{:definition, goal(goal, "", @semi) <> "."} | clauses(rest, defined)]

  defp clauses([goal | rest], defined), do: [goal_clause(goal) | clauses(rest, defined)]

  defp goal_clause(goal), do: {:goal, goal(goal, "", @semi) <> "."}

  defp full_stop(body), do: if(trailing_comment?(body), do: "\n.", else: ".")

  defp trailing_comment?(body), do: body != [] and comment?(List.last(body))

  @spec body([term()]) :: String.t()
  def body(goals), do: goals |> lines("") |> Enum.join("\n")

  @spec goal(term()) :: String.t()
  def goal(goal), do: goal(load(goal), "", @semi)

  @spec term(term()) :: String.t()
  def term(term) when is_tuple(term), do: term(Goal.from_stored(term), "", @semi)
  def term(term), do: term(term, "", @semi)

  defp load(goal) when goal in [:cut, :fail, :pass], do: Goal.from_stored(goal)
  defp load(goal) when is_tuple(goal) and not is_struct(goal), do: Goal.from_stored(goal)
  defp load(goal), do: goal

  defp method(owner, selector, head, body, indent) do
    prefix = term(owner, indent, @primary) <> " >> " <> atom(selector)

    header =
      prefix <> "\n" <> indent <> Enum.join(["|" | head_items(head, indent)] ++ ["|"], " ")

    case body do
      [] ->
        header

      body ->
        header <> "\n" <> Enum.map_join(lines(body, indent), "\n", &(indent <> &1))
    end
  end

  defp head_items([], _indent), do: []

  defp head_items([item | rest], indent) when is_list(rest),
    do: [term(item, indent, @primary) | head_items(rest, indent)]

  defp head_items([item | tail], indent),
    do: [term(item, indent, @primary), ".", term(tail, indent, @primary)]

  defp head_items(tail, indent), do: [".", term(tail, indent, @primary)]

  defp goal(goal, indent, context)
       when goal in [:cut, :fail, :pass] or (is_tuple(goal) and not is_struct(goal)),
       do: goal(load(goal), indent, context)

  defp goal(goal, indent, context) when is_atom(goal), do: term(goal, indent, context)

  defp goal(
         %Goal.OApply{method_id: :defmethod, args: [class, selector, head, body]},
         indent,
         context
       )
       when is_list(body),
       do:
         applied(
           :defmethod,
           [
             argument(class, indent),
             argument(selector, indent),
             argument(head, indent),
             block(body, indent)
           ],
           context
         )

  defp goal(
         %Goal.OApply{
           method_id: :defclass,
           args: [name, metaclass, super, ivars, categories]
         },
         indent,
         context
       ) do
    options =
      [
        super: super,
        metaclass: metaclass,
        ivars: ivars,
        categories: categories
      ]
      |> Enum.reject(fn {key, value} -> value == default(key) end)
      |> Enum.map(fn {key, value} -> "#{key}: #{term(value, indent <> "  ")}" end)

    wrap(
      "@" <>
        term(name, indent, @primary) <> "\n" <> indent <> layout("\#{", options, "}", indent),
      @semi,
      context
    )
  end

  defp goal(%Goal.OApply{method_id: :extend_class, args: [name, supers]}, indent, context)
       when is_list(supers),
       do:
         wrap(
           "@+" <>
             term(name, indent, @primary) <>
             "\n" <>
             indent <>
             layout("\#{", ["super: " <> term(supers, indent <> "  ")], "}", indent),
           @semi,
           context
         )

  defp goal(%Goal.OApply{method_id: :clear_method, args: [owner, selector]}, indent, context),
    do: call(:clear_method, [owner, selector], indent, context)

  defp goal(%Goal.OApply{method_id: :spawn_transaction, args: [goals]}, indent, context)
       when is_list(goals) and goals != [],
       do: applied(:spawn, [block(goals, indent)], context)

  defp goal(%Goal.OApply{method_id: :await_effect, args: [effect, head, goals]}, indent, context)
       when is_list(head) and is_list(goals) and goals != [],
       do:
         applied(
           :await,
           [argument(effect, indent), argument(head, indent), block(goals, indent)],
           context
         )

  defp goal(%Goal.OApply{method_id: op, args: [left, right]}, indent, context)
       when op in [:+, :-, :*, :/, :**, :rem],
       do: infix(op, left, right, indent, context)

  defp goal(%Goal.OApply{method_id: :-, args: [operand]}, indent, context) do
    operand =
      if is_number(operand),
        do: "(#{term(operand, indent)})",
        else: term(operand, indent, @primary)

    wrap("-" <> operand, @unary, context)
  end

  defp goal(%Goal.OApply{method_id: method_id, args: args}, indent, context)
       when is_atom(method_id) and is_list(args) do
    cond do
      AL.Var.var?(method_id) ->
        call(:vm_oapply, [method_id, args], indent, context)

      Syntax.primitive?(method_id) ->
        call(method_id, args, indent, context)

      args == [] and not Syntax.reserved?(method_id) and method_id not in [:cut, :fail, :pass] ->
        wrap(atom(method_id), @primary, context)

      true ->
        call(:vm_oapply, [method_id, args], indent, context)
    end
  end

  defp goal(%Goal.OApply{method_id: method_id, args: args}, indent, context),
    do: call(:vm_oapply, [method_id, args], indent, context)

  defp goal(%Goal.Send{object: object, method: :lambda, args: [method, body]}, indent, context)
       when is_list(body),
       do:
         applied(
           :lambda,
           [argument(object, indent), argument(method, indent), block(body, indent)],
           context
         )

  defp goal(%Goal.Send{object: object, method: method, args: args}, indent, context) do
    cond do
      not is_list(args) ->
        call(:send, [object, method, args], indent, context)

      not is_atom(method) or AL.Var.var?(method) or Syntax.reserved?(method) ->
        if args == [],
          do: call(:send, [object, method], indent, context),
          else: call(:send, [object, method, args], indent, context)

      true ->
        call(method, [object | args], indent, context)
    end
  end

  defp goal(%Goal.CallNextMethod{self: self, args: args}, indent, context) when is_list(args),
    do: call(:call_next_method, [self | args], indent, context)

  defp goal(%Goal.Cut{}, _indent, _context), do: "cut"
  defp goal(%Goal.Fail{}, _indent, _context), do: "fail"
  defp goal(%Goal.Pass{}, _indent, _context), do: "pass"

  defp goal(
         %Goal.Implies{condition: condition, then: then, otherwise: otherwise},
         indent,
         context
       ) do
    pair = sequence(condition, indent, @either) <> " -> " <> sequence(then, indent, @either)

    case otherwise do
      [%Goal.Fail{}] ->
        wrap(pair, @arrow, context)

      [] ->
        wrap(pair <> " ; {}", @semi, context)

      [%Goal.Implies{} = next] ->
        wrap(pair <> " ; " <> goal(next, indent, @semi), @semi, context)

      otherwise ->
        wrap(pair <> " ; " <> sequence(otherwise, indent, @semi), @semi, context)
    end
  end

  defp goal(%Goal.Or{or: left, then: right}, indent, context),
    do:
      wrap(
        sequence(left, indent, @either) <> " ; " <> sequence(right, indent, @semi),
        @semi,
        context
      )

  defp goal(
         %Goal.Findall{template: template, condition: condition, result: result},
         indent,
         context
       )
       when is_list(condition),
       do:
         applied(
           :findall,
           [argument(template, indent), argument(result, indent), block(condition, indent)],
           context
         )

  defp goal(%Goal.Forall{condition: condition, body: body}, indent, context) when is_list(body),
    do: applied(:forall, [goal_group(condition, indent), block(body, indent)], context)

  defp goal(%Goal.Not{condition: condition}, indent, context),
    do: applied(:not, [goal_group(condition, indent)], context)

  defp goal(%Goal.Freeze{var: var, goals: goals}, indent, context),
    do: applied(:freeze, [argument(var, indent), goal_group(goals, indent)], context)

  defp goal(%Goal.Call{head: head, body: body, args: args}, indent, context),
    do:
      applied(
        :call,
        [argument(head, indent), goal_group(body, indent), argument(args, indent)],
        context
      )

  defp goal(%Goal.SetOapply{object: object, seq: :next, head: head, body: body}, indent, context),
    do:
      applied(
        :vm_set_oapply,
        [argument(object, indent), argument(head, indent), goal_group(body, indent)],
        context
      )

  defp goal(%Goal.SetOapply{object: object, seq: seq, head: head, body: body}, indent, context),
    do:
      applied(
        :vm_set_oapply,
        [
          argument(object, indent),
          argument(seq, indent),
          argument(head, indent),
          goal_group(body, indent)
        ],
        context
      )

  defp goal(%Goal.SourceScope{capture_id: capture_id, goals: goals}, indent, context)
       when is_list(goals),
       do:
         applied(:vm_source_scope, [argument(capture_id, indent), block(goals, indent)], context)

  defp goal(%Goal.Either{left: left, right: right}, indent, context),
    do:
      wrap(
        goal(left, indent, @either) <> " or " <> goal(right, indent, @comparison),
        @either,
        context
      )

  defp goal(%Goal.Compare{op: op, a: a, b: b}, indent, context),
    do: comparison(op, a, b, indent, context)

  defp goal(%Goal.Eq{a: a, b: b}, indent, context), do: comparison(:=, a, b, indent, context)
  defp goal(%Goal.Equal{a: a, b: b}, indent, context), do: comparison(:==, a, b, indent, context)

  defp goal(%Goal.Comment{text: text}, indent, context),
    do: call(:comment, [text], indent, context)

  defp goal(%Goal.GetOapply{object: object, seq: :"$_", head: head, body: body}, indent, context),
    do: call(:clause, [object, head, body], indent, context)

  defp goal(
         %Goal.GetSlots{object: object, key: key, value: value, store: :auto},
         indent,
         context
       ),
       do: call(:slot, [object, key, value], indent, context)

  defp goal(%Goal.SendAsync{object: object, method: method, args: []}, indent, context),
    do: call(:send_async, [object, method], indent, context)

  defp goal(goal, indent, context) when is_struct(goal) do
    case simple(goal) do
      {name, fields} -> call(name, Enum.map(fields, &Map.fetch!(goal, &1)), indent, context)
      nil -> raise ArgumentError, "#{inspect(goal)} has no AL syntax"
    end
  end

  defp simple(%Goal.GetClass{}), do: {:class, [:object, :class]}
  defp simple(%Goal.GetSuper{}), do: {:super, [:object, :super]}
  defp simple(%Goal.AssertValidClauseSelf{}), do: {:vm_assert_valid_clause_self, [:class, :head]}
  defp simple(%Goal.GetMethod{}), do: {:method, [:object, :name, :id]}
  defp simple(%Goal.GetCommand{}), do: {:vm_command, [:transaction, :time, :operation]}
  defp simple(%Goal.GetOapply{}), do: {:clause, [:object, :seq, :head, :body]}
  defp simple(%Goal.TransactionSource{}), do: {:vm_transaction_source, [:tx, :text, :origin]}

  defp simple(%Goal.MethodSource{}),
    do: {:vm_method_source, [:object, :seq, :text, :provenance]}

  defp simple(%Goal.SetClass{}), do: {:vm_set_class, [:object, :class]}
  defp simple(%Goal.SetSuper{}), do: {:vm_set_super, [:object, :super]}
  defp simple(%Goal.SetMethod{}), do: {:vm_set_method, [:object, :name, :id]}
  defp simple(%Goal.SetSlot{}), do: {:vm_set_slot, [:object, :key, :value]}
  defp simple(%Goal.GetSlots{}), do: {:slot, [:object, :key, :value, :store]}
  defp simple(%Goal.GetSlotAt{}), do: {:vm_slot_at, [:object, :key, :value, :t]}
  defp simple(%Goal.RetractClass{}), do: {:vm_retract_class, [:object, :class]}
  defp simple(%Goal.RetractSuper{}), do: {:vm_retract_super, [:object, :super]}
  defp simple(%Goal.RetractMethod{}), do: {:vm_retract_method, [:object, :name, :id]}
  defp simple(%Goal.RetractOapply{}), do: {:vm_retract_oapply, [:object, :head]}
  defp simple(%Goal.RetractSlot{}), do: {:vm_retract_slot, [:object, :key]}
  defp simple(%Goal.Gensym{}), do: {:gensym, [:var]}
  defp simple(%Goal.Format{}), do: {:vm_format, [:control, :args]}
  defp simple(%Goal.Ground{}), do: {:ground, [:term]}
  defp simple(%Goal.Label{}), do: {:label, [:term]}
  defp simple(%Goal.IsVar{}), do: {:var, [:term]}
  defp simple(%Goal.Dif{}), do: {:dif, [:a, :b]}
  defp simple(%Goal.Isa{}), do: {:isa, [:object, :class]}
  defp simple(%Goal.InDomain{}), do: {:in_domain, [:var, :values]}
  defp simple(%Goal.AllDif{}), do: {:all_dif, [:vars]}
  defp simple(%Goal.FloorDivide{}), do: {:floor_divide, [:dividend, :divisor, :quotient]}
  defp simple(%Goal.SendAsync{}), do: {:send_async, [:object, :method, :args]}
  defp simple(%Goal.SendElixir{}), do: {:send_elixir, [:pid, :message]}

  defp simple(%Goal.EmitEffect{}),
    do: {:vm_emit_effect, [:effect, :provider, :operation, :arguments]}

  defp simple(_goal), do: nil

  defp comparison(op, a, b, indent, context),
    do:
      wrap(
        "#{term(a, indent, @additive)} #{op} #{term(b, indent, @additive)}",
        @comparison,
        context
      )

  defp infix(op, left, right, indent, context) do
    {level, left_context, right_context} =
      case op do
        op when op in [:+, :-] -> {@additive, @additive, @multiplicative}
        op when op in [:*, :/, :rem] -> {@multiplicative, @multiplicative, @power}
        :** -> {@power, @primary, @power}
      end

    wrap(
      "#{term(left, indent, left_context)} #{op} #{term(right, indent, right_context)}",
      level,
      context
    )
  end

  defp wrap(text, level, context) when level < context, do: "(" <> text <> ")"
  defp wrap(text, _level, _context), do: text

  defp default(:metaclass), do: :class
  defp default(:ivars), do: []
  defp default(:categories), do: []
  defp default(:super), do: :__al_always_printed__

  defp lines(goals, indent) do
    real = Enum.count(goals, &(not comment?(&1)))

    {lines, _seen} =
      Enum.map_reduce(goals, 0, fn goal, seen ->
        if comment?(goal) do
          {"#" <> comment_text(goal), seen}
        else
          text = goal(load(goal), indent, @semi)
          {if(seen + 1 < real, do: text <> ",", else: text), seen + 1}
        end
      end)

    lines
  end

  defp comment?(%Goal.Comment{}), do: true
  defp comment?({:comment, _text}), do: true
  defp comment?(_goal), do: false

  defp comment_text(%Goal.Comment{text: text}), do: text
  defp comment_text({:comment, text}), do: text

  defp sequence(goals, indent, context) when is_list(goals) do
    case goals do
      [single] ->
        if comment?(single),
          do: block(goals, indent),
          else: goal(load(single), indent, context)

      goals ->
        block(goals, indent)
    end
  end

  defp sequence(goals, indent, context), do: term(goals, indent, context)

  defp goal_group(goals, indent) when is_list(goals), do: block(goals, indent)
  defp goal_group(goals, indent), do: term(goals, indent, @primary)

  defp block([], _indent), do: "{}"

  defp block(goals, indent) do
    inline = "{" <> Enum.map_join(goals, ", ", &goal(load(&1), indent, @semi)) <> "}"

    if Enum.any?(goals, &comment?/1) or String.contains?(inline, "\n") or
         String.length(inline) > 72 do
      inner = indent <> "  "
      "{\n" <> Enum.map_join(lines(goals, inner), "\n", &(inner <> &1)) <> "\n" <> indent <> "}"
    else
      inline
    end
  end

  defp call(name, args, indent, context),
    do: applied(name, Enum.map(args, &argument(&1, indent)), context)

  defp applied(name, [], context), do: wrap(atom(name), @call, context)

  defp applied(name, arguments, context),
    do: wrap(Enum.join([atom(name) | arguments], " "), @call, context)

  defp argument(term, indent), do: term(term, indent, @primary)

  defp term(term, indent), do: term(term, indent, @semi)

  defp term({:unquote, _, [{name, _, context}]}, _indent, _context)
       when is_atom(name) and is_atom(context),
       do: "^#{name}"

  defp term(%Goal.OApply{method_id: method_id, args: []} = goal, indent, context)
       when is_atom(method_id) do
    if AL.Var.var?(method_id) or Syntax.reserved?(method_id) or
         method_id in [:cut, :fail, :pass] or Syntax.primitive?(method_id),
       do: goal(goal, indent, context),
       else: "(#{atom(method_id)})"
  end

  defp term(term, indent, context) when is_struct(term), do: goal(term, indent, context)

  defp term(term, indent, _context) when is_map(term) do
    inner = indent <> "  "

    entries =
      Enum.map(Enum.sort(term), fn
        {key, value} when is_atom(key) and not is_nil(key) and not is_boolean(key) ->
          if AL.Var.var?(key),
            do: "#{term(key, inner)} => #{term(value, inner)}",
            else: "#{atom(key)}: #{term(value, inner)}"

        {key, value} ->
          "#{term(key, inner)} => #{term(value, inner)}"
      end)

    layout("\#{", entries, "}", indent)
  end

  defp term(term, indent, _context) when is_list(term),
    do: layout("[", items(term, indent <> "  "), "]", indent)

  defp term(term, _indent, _context) when is_atom(term) do
    if AL.Var.var?(term), do: variable(term), else: atom(term)
  end

  defp term(term, _indent, _context) when is_number(term) or is_binary(term), do: literal(term)

  defp term(term, _indent, _context),
    do: raise(ArgumentError, "#{inspect(term)} has no AL syntax")

  defp items([], _indent), do: []

  defp items([item | rest], indent) when is_list(rest),
    do: [term(item, indent) | items(rest, indent)]

  defp items([item | tail], indent), do: [term(item, indent) <> " . " <> term(tail, indent)]

  @width 80

  defp layout(open, entries, close, indent) do
    inline = open <> Enum.join(entries, ", ") <> close

    if entries == [] or
         (not String.contains?(inline, "\n") and String.length(indent <> inline) <= @width) do
      inline
    else
      inner = indent <> "  "
      open <> "\n" <> Enum.map_join(entries, ",\n", &(inner <> &1)) <> "\n" <> indent <> close
    end
  end

  defp variable(var) do
    name = var |> Atom.to_string() |> String.trim_leading("$")
    if name =~ ~r/^[A-Z_]/, do: name, else: camelize(name)
  end

  @spec camelize(String.t()) :: String.t()
  def camelize("_" <> rest), do: "_" <> camelize(rest)

  def camelize(name) do
    name
    |> String.split("_")
    |> Enum.map_join(&upcase_first/1)
  end

  defp upcase_first(""), do: ""
  defp upcase_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  defp atom(atom) when atom in [nil, true, false], do: Atom.to_string(atom)

  defp atom(atom) do
    text = Atom.to_string(atom)

    if text =~ ~r/^[a-z][a-zA-Z0-9_]*$/ and text not in ["rem", "or"],
      do: text,
      else: "'" <> (text |> String.replace("\\", "\\\\") |> String.replace("'", "\\'")) <> "'"
  end

  defp literal(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)
end
