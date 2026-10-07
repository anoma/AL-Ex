defmodule AL.JAM.Compiler do
  alias AL.Goal

  def fetch_ir(method_id, branch) do
    AL.ResolutionCache.fetch_dispatch(branch, {:method_ir, method_id}, fn ->
      method_id |> AL.cached_scan_clauses(branch) |> AL.JAM.IR.Program.lower_clauses()
    end)
  end

  def fetch_method(method_id, branch) do
    compile = fn ->
      clauses = fetch_ir(method_id, branch)
      AL.JAM.IR.MethodIdentity.prepare(compile(clauses), clauses, method_id)
    end

    if AL.JAM.Trace.active?(),
      do: AL.ResolutionCache.fetch_dispatch(branch, {:traced_method, method_id}, compile),
      else: AL.ResolutionCache.fetch_compiled_method(branch, method_id, compile)
  end

  def fetch_callable(head, body, branch) when is_list(body) do
    {head, body, environment, captures} = callable_source(head, body)

    template =
      AL.ResolutionCache.fetch_dispatch(branch, {:closure, head, body}, fn ->
        compile_template(head, body, environment)
      end)

    {template, captures}
  end

  def fetch_callable(_head, body, _branch),
    do: raise(ArgumentError, "call needs a bound body, got #{inspect(body)}")

  def callable_template(head, body) do
    {head, body, environment, captures} = callable_source(head, body)
    {compile_template(head, body, environment), captures}
  end

  defp callable_source(head, body) do
    body = Enum.map(body, &Goal.from_stored/1)

    {variables, captures} =
      Goal.reduce({head, body}, {%{}, []}, fn term, {variables, captures} ->
        if term != :"$_" and AL.Var.var?(term) and not Map.has_key?(variables, term) do
          name = AL.Var.fresh(:"$Capture", Integer.to_string(map_size(variables)))
          {Map.put(variables, term, name), [term | captures]}
        else
          {variables, captures}
        end
      end)

    captures = Enum.reverse(captures)
    {head, body} = Goal.map({head, body}, &Map.get(variables, &1, &1))
    environment = Enum.map(captures, &Map.fetch!(variables, &1))
    {head, body, environment, captures}
  end

  defp compile_template(head, body, environment) do
    {[{identity, matcher, initial, locals, code, _}], _} =
      compile_with_captures([{:oapply, :call, 0, head, body}], false, environment)

    slots = environment |> Enum.sort() |> Enum.with_index() |> Map.new()

    %AL.JAM.Callable.Template{
      matcher: matcher,
      initial: initial,
      locals: locals,
      code: code,
      head: elem(identity, 3),
      capture_slots: Enum.map(environment, &Map.fetch!(slots, &1))
    }
  end

  def compile(clauses, return_modes \\ true) do
    compile_with_captures(clauses, return_modes, [])
  end

  defp compile_with_captures(clauses, return_modes, captures) do
    clauses = AL.JAM.IR.Program.lower_clauses(clauses)
    rejections = AL.JAM.IR.Rejection.compile(clauses)
    clauses = prepare(clauses, captures, return_modes and not AL.JAM.Trace.active?())

    compiled =
      Enum.map(clauses, fn {identity, matcher, initial, locals, code} ->
        code = AL.JAM.Registers.specialize(code, locals)
        local_indices = MapSet.new(locals, &elem(&1, 0))

        variants =
          for true <- [return_modes],
              index <- 0..(tuple_size(initial) - 1)//1,
              tuple_size(initial) > 0,
              not MapSet.member?(local_indices, index),
              specialized = AL.JAM.Registers.specialize(code, [{index, nil}]),
              Enum.any?(Enum.zip(code, specialized), fn {before, after_code} ->
                before != after_code and elem(after_code, 0) != :send_local
              end),
              into: %{},
              do:
                {index,
                 code
                 |> Enum.zip(specialized)
                 |> Enum.with_index()
                 |> Enum.flat_map(fn {{before, after_code}, pc} ->
                   if before == after_code, do: [], else: [{pc, return_patch(after_code)}]
                 end)}

        head_returns =
          if return_modes and code == [],
            do: AL.JAM.Head.return_arguments(matcher),
            else: %{}

        {code, initial} =
          if return_modes,
            do: AL.JAM.Self.compile(code, matcher, initial),
            else: {code, initial}

        matcher = AL.JAM.Head.arguments(matcher)
        locals = AL.JAM.Registers.materialized_locals(code, locals)
        {identity, matcher, initial, locals, List.to_tuple(code), {variants, head_returns}}
      end)

    index = AL.ClauseIndex.build(compiled)

    index = AL.JAM.IR.Rejection.index(rejections, compiled, index)

    planning =
      Enum.any?(compiled, fn {_, _, _, _, code, _} ->
        code
        |> Tuple.to_list()
        |> Enum.drop_while(fn
          {:local, _, {:eq, _, _}} -> true
          {:cursor, _} -> true
          _ -> false
        end)
        |> case do
          [{:send, _, _, _, _} | _] -> true
          [{:send_local, _, _} | _] -> true
          [{:next, _, _, _} | _] -> true
          _ -> false
        end
      end)

    index =
      if planning,
        do: Map.put(index || %{literal: nil, list_indices: []}, :planning, true),
        else: index

    {compiled, index}
  end

  defp return_patch({:local, index, _operation}), do: {:local, index}
  defp return_patch({:send_local, _operation, destinations}), do: {:send_local, destinations}

  defp return_patch({:collect, _template, {:destination, index}, _condition}),
    do: {:destination, index}

  defp prepare(clauses, captures, inline?) do
    captures = MapSet.new(captures)

    scoped? =
      Enum.any?(clauses, fn {:oapply, _, _, _, body} ->
        AL.JAM.IR.contains?(body, :cut)
      end)

    Enum.map(clauses, fn {:oapply, id, seq, head, body} ->
      body =
        if inline?,
          do: AL.JAM.IR.Inline.callables(body, MapSet.union(AL.Var.find_vars(head), captures)),
          else: body

      body =
        body
        |> AL.JAM.IR.Region.compile(MapSet.union(AL.Var.find_vars(head), captures))
        |> AL.JAM.IR.Selection.select()

      cursor? = AL.JAM.IR.contains?(body, :next)

      names =
        MapSet.union(AL.Var.find_vars(head), AL.JAM.IR.Program.variables(body))
        |> MapSet.delete(:"$_")
        |> MapSet.difference(captures)
        |> Enum.sort()

      names = Enum.sort(captures) ++ names
      slots = names |> Enum.with_index() |> Map.new()
      slots = if cursor?, do: Map.put(slots, :jam_cursor, length(names)), else: slots
      {matcher, seen} = AL.JAM.Head.compile(head, slots, captures)
      locals = Enum.reject(names, &MapSet.member?(seen, &1))
      initial = List.duplicate(nil, map_size(slots)) |> List.to_tuple()
      locals = Enum.map(locals, &{Map.fetch!(slots, &1), &1})
      head_slots = Enum.map(seen, &Map.fetch!(slots, &1))
      body_slots = Map.put(slots, :jam_head_slots, head_slots)
      builders = AL.JAM.IR.Program.emit(body, body_slots)

      builders =
        if scoped?, do: [:cut_scope | builders], else: builders

      builders =
        if cursor?, do: [{:cursor, Map.fetch!(slots, :jam_cursor)} | builders], else: builders

      {{id, seq, head, AL.JAM.Operand.compile(head, slots)}, matcher, initial, locals, builders}
    end)
  end

  def runtime(goals) do
    program = AL.JAM.IR.Program.lower(goals)

    variables =
      program |> AL.JAM.IR.Program.variables() |> MapSet.delete(:"$_") |> MapSet.to_list()

    slots = variables |> Enum.with_index() |> Map.new()
    {AL.JAM.IR.Program.emit(program, slots) |> List.to_tuple(), List.to_tuple(variables)}
  end
end
