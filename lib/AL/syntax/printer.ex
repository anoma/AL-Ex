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
  @call 8
  @operators [:=, :==, :<, :>, :<=, :>=, :+, :-, :*, :/, :**]
  @primary 9
  @statements [:defmethod, :clear_method, :defclass, :extend_class]
  @syntax [
    :";",
    :->,
    :findall,
    :forall,
    :not,
    :freeze,
    :spawn,
    :await,
    :lambda,
    :call,
    :vm_source_scope,
    :vm_set_oapply,
    :comment,
    :cut,
    :fail,
    :pass
  ]

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
       do: [{:definition, declaration(goal, "") <> "."} | clauses(rest, defined)]

  defp clauses([goal | rest], defined), do: [goal_clause(goal) | clauses(rest, defined)]

  defp goal_clause(goal), do: {:goal, goal(goal, "", @semi) <> "."}

  defp full_stop(body), do: if(trailing_comment?(body), do: "\n.", else: ".")

  defp trailing_comment?(body), do: body != [] and comment?(List.last(body))

  @spec body([term()]) :: String.t()
  def body(goals), do: goals |> lines("") |> Enum.join("\n")

  @spec goal(term()) :: String.t()
  def goal(goal), do: declaration(load(goal), "")

  @spec term(term()) :: String.t()
  def term(term) when is_tuple(term), do: term(Goal.from_stored(term), "", @semi)
  def term(term), do: term(term, "", @semi)

  defp load(goal) when goal in [:cut, :fail, :pass], do: Goal.from_stored(goal)
  defp load(goal) when is_tuple(goal) and not is_struct(goal), do: Goal.from_stored(goal)

  defp load(%Goal.Compound{name: name} = compound) when name in @statements,
    do: Goal.lower(compound)

  defp load(goal), do: goal

  defp method(owner, selector, head, body, indent) do
    prefix = term(owner, indent, @primary) <> " >> " <> term(selector, indent, @primary)

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

  defp declaration(
         %Goal.OApply{
           method_id: :defclass,
           args: [name, metaclass, super, ivars, categories]
         },
         indent
       ) do
    options =
      [
        super: super,
        metaclass: metaclass,
        ivars: ivars,
        categories: categories
      ]
      |> Enum.reject(fn {key, value} -> value == default(key) end)
      |> Enum.map(fn {key, value} -> "#{atom(key)} => #{term(value, indent <> "  ")}" end)

    "@" <> term(name, indent, @primary) <> "\n" <> indent <> layout("\#{", options, "}", indent)
  end

  defp declaration(%Goal.OApply{method_id: :extend_class, args: [name, supers]}, indent)
       when is_list(supers),
       do:
         "@+" <>
           term(name, indent, @primary) <>
           "\n" <>
           indent <>
           layout("\#{", ["super => " <> term(supers, indent <> "  ")], "}", indent)

  defp declaration(goal, indent), do: goal(goal, indent, @semi)

  defp goal(%Goal.Compound{name: name} = compound, indent, context) when name in @syntax,
    do: goal(Goal.lower(compound), indent, context)

  defp goal(%Goal.Compound{name: name, args: args}, indent, context),
    do: call(name, args, indent, context)

  defp goal({:"$var", _} = variable, indent, context), do: term(variable, indent, context)
  defp goal({:"$fresh", _, _} = variable, indent, context), do: term(variable, indent, context)

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
             goal_group(body, indent)
           ],
           context
         )

  defp goal(%Goal.OApply{method_id: :clear_method, args: [owner, selector]}, indent, context),
    do: call(:clear_method, [owner, selector], indent, context)

  defp goal(%Goal.OApply{method_id: :spawn_transaction, args: [goals]}, indent, context)
       when is_list(goals) and goals != [],
       do: applied(:spawn, [goal_group(goals, indent)], context)

  defp goal(%Goal.OApply{method_id: :await_effect, args: [effect, head, goals]}, indent, context)
       when is_list(head) and is_list(goals) and goals != [],
       do:
         applied(
           :await,
           [argument(effect, indent), argument(head, indent), goal_group(goals, indent)],
           context
         )

  defp goal(%Goal.OApply{method_id: op, args: args}, indent, context)
       when op in [:+, :-, :*, :/, :**, :rem] and is_list(args) and args != [],
       do: call(op, args, indent, context)

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
           [argument(object, indent), argument(method, indent), goal_group(body, indent)],
           context
         )

  defp goal(%Goal.Send{object: object, method: method, args: args}, indent, context) do
    cond do
      not is_list(args) ->
        call(:send, [object, method, args], indent, context)

      not is_atom(method) or Syntax.reserved?(method) ->
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
           [argument(template, indent), argument(result, indent), goal_group(condition, indent)],
           context
         )

  defp goal(%Goal.Forall{condition: condition, body: body}, indent, context) when is_list(body),
    do: applied(:forall, [goal_group(condition, indent), goal_group(body, indent)], context)

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
         applied(
           :vm_source_scope,
           [argument(capture_id, indent), goal_group(goals, indent)],
           context
         )

  defp goal(%Goal.Either{left: left, right: right}, indent, context),
    do: call(:or, [left, right], indent, context)

  defp goal(%Goal.Compare{op: op, a: a, b: b}, indent, context),
    do: call(op, [a, b], indent, context)

  defp goal(%Goal.Eq{a: a, b: b}, indent, context), do: call(:=, [a, b], indent, context)
  defp goal(%Goal.Equal{a: a, b: b}, indent, context), do: call(:==, [a, b], indent, context)

  defp goal(%Goal.Comment{text: text}, indent, context),
    do: call(:comment, [text], indent, context)

  defp goal(goal, indent, context) when is_struct(goal) do
    case Goal.to_call(goal) do
      {name, args} -> call(name, args, indent, context)
      nil -> raise ArgumentError, "#{inspect(goal)} has no AL syntax"
    end
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
  defp comment?(%Goal.Compound{name: :comment, args: [text]}) when is_binary(text), do: true
  defp comment?({:compound, :comment, [text]}) when is_binary(text), do: true
  defp comment?({:comment, _text}), do: true
  defp comment?(_goal), do: false

  defp comment_text(%Goal.Comment{text: text}), do: text
  defp comment_text(%Goal.Compound{name: :comment, args: [text]}), do: text
  defp comment_text({:compound, :comment, [text]}), do: text
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

  defp goal_group([single], indent) do
    if comment?(single),
      do: block([single], indent),
      else: "(" <> goal(load(single), indent, @semi) <> ")"
  end

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

  defp term(%Goal.Compound{name: name, args: []}, _indent, _context) when is_atom(name),
    do: "(#{atom(name)})"

  defp term(%Goal.Compound{} = compound, indent, context), do: goal(compound, indent, context)

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

  defp term({:"$var", _} = term, _indent, _context), do: variable(term)
  defp term({:"$fresh", _, _} = term, _indent, _context), do: variable(term)

  defp term(term, indent, context) when is_tuple(term) do
    case Goal.from_stored(term) do
      goal when is_struct(goal) -> term(goal, indent, context)
      _ -> raise ArgumentError, "#{inspect(term)} has no AL syntax"
    end
  end

  defp term(term, indent, _context) when is_map(term) do
    inner = indent <> "  "

    entries =
      Enum.map(Enum.sort(term), fn {key, value} ->
        "#{term(key, inner)} => #{term(value, inner)}"
      end)

    layout("\#{", entries, "}", indent)
  end

  defp term(term, indent, _context) when is_list(term),
    do: layout("[", items(term, indent <> "  "), "]", indent)

  defp term(term, _indent, _context) when is_atom(term), do: atom(term)

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
    name = AL.Var.name(var)

    cond do
      String.starts_with?(name, "_@") -> "_"
      match?(<<c, _::binary>> when c in ?A..?Z or c == ?_, name) -> name
      true -> camelize(name)
    end
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

    if plain_atom?(text) or atom in @operators,
      do: text,
      else: "'" <> (text |> String.replace("\\", "\\\\") |> String.replace("'", "\\'")) <> "'"
  end

  defp plain_atom?(<<c, rest::binary>>) when c in ?a..?z, do: name_chars?(rest)
  defp plain_atom?(_text), do: false

  defp name_chars?(<<>>), do: true

  defp name_chars?(<<c, rest::binary>>)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_,
       do: name_chars?(rest)

  defp name_chars?(_text), do: false

  defp literal(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)
end
