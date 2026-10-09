Code.require_file("language_support.exs", __DIR__)

defmodule Bench.ParseBoundaryProfile do
  def patch!(source, before, replacement) do
    if length(String.split(source, before)) != 2, do: raise("boundary profiling hook changed")
    String.replace(source, before, replacement, global: false)
  end

  def active?, do: Process.get(:boundary_enabled, false)

  def bump(key),
    do: Process.put({:boundary_count, key}, Process.get({:boundary_count, key}, 0) + 1)

  def selector({:provider, _, {selector, _}, _}), do: selector
  def selector({:provider, _, {selector, _}}), do: selector
  def selector({:cut_scope, _, id}), do: selector(id)
  def selector(_), do: :root

  def method_id({:provider, id, _, _}), do: id
  def method_id({:provider, id, _}), do: id
  def method_id({:cut_scope, _, id}), do: method_id(id)
  def method_id(_), do: nil

  def send(caller, pc, operation, object, method, slots, store) do
    if active?() do
      {:send, site, receiver_operand, method_operand, args} = operation
      values = AL.JAM.Operand.resolve(args, slots, store)

      key =
        {method_id(caller), pc, selector(caller), method, inspect(receiver_operand),
         inspect(method_operand), inspect(args)}

      bump({:send, key})

      sample = %{
        caller: selector(caller),
        caller_method: method_id(caller),
        pc: pc,
        selector: method,
        site: inspect(site),
        receiver: inspect(object),
        literal_selector: match?({:constant, _}, method_operand),
        literal_receiver: match?({:constant, _}, receiver_operand),
        operands: inspect({receiver_operand, method_operand, args}),
        arguments: Enum.map(values, &shape/1)
      }

      if Process.get({:boundary_sample, key}) == nil,
        do: Process.put({:boundary_sample, key}, sample)

      Process.put(:boundary_path, [sample | Process.get(:boundary_path, [])])
    end
  end

  def target({:provider, id, _cursor}, method) do
    if active?(), do: Process.put({:boundary_method, id}, method)
  end

  def target(_, _), do: :ok

  def scan_admission(selector, input, rest, output, store) do
    if active?() do
      first =
        case input do
          [first | _] when is_integer(first) -> first
          _ -> :non_character
        end

      status = fn value ->
        cond do
          not AL.Var.var?(value) -> :bound
          Map.has_key?(store, value) -> :constrained_or_bound
          value == {:"$var", "_"} -> :wildcard
          true -> :fresh
        end
      end

      bump({:scan_admission, selector, first, status.(rest), status.(output)})
    end
  end

  def scan_prefix(plan, [first | _]) do
    if active?() do
      rejected =
        first == ?$ or
          Enum.any?(plan.reject, fn paths ->
            Enum.any?(paths, fn tests ->
              Enum.all?(tests, fn
                {:eq, bound} -> first == bound
                {:>=, bound} -> first >= bound
                {:<=, bound} -> first <= bound
                {:>, bound} -> first > bound
                {:<, bound} -> first < bound
              end)
            end)
          end)

      bump({:scan_prefix, first, rejected})
    end
  end

  def reset do
    for {key, _} <- Process.get(),
        is_tuple(key),
        elem(key, 0) in [
          :boundary_count,
          :boundary_sample,
          :boundary_match,
          :boundary_entry,
          :boundary_choice,
          :boundary_method
        ],
        do: Process.delete(key)

    Process.put(:boundary_path, [])
  end

  def counts, do: Map.new(for {{:boundary_count, key}, count} <- Process.get(), do: {key, count})

  def symbol_runs(path) do
    family = [
      :symbol,
      :integer,
      :natural,
      :symbol_code,
      :zero_or_more,
      :code,
      :variable_name,
      :within,
      :sequence,
      :match_pattern,
      :concat,
      :unless,
      :integer_name
    ]

    runs =
      for {sample, start} <- Enum.with_index(path),
          sample.selector == :symbol and sample.caller not in family do
        nested = path |> Enum.drop(start + 1) |> Enum.take_while(&(&1.caller in family))

        prefix =
          case sample.arguments do
            [%{kind: :list, prefix: prefix} | _] -> prefix
            _ -> []
          end

        kind =
          case prefix do
            [first | _] when first in ?A..?Z or first == ?_ -> :uppercase
            [] -> :empty_input
            _ -> if nested == [], do: :single_send, else: :other_generic
          end

        %{
          start: start,
          stop: start + length(nested) + 1,
          sends: length(nested) + 1,
          caller: sample.caller,
          prefix: prefix,
          kind: kind
        }
      end

    for [left, right] <- Enum.chunk_every(runs, 2, 1, :discard) do
      if left.stop > right.start, do: raise("overlapping symbol runs")
    end

    %{
      runs: runs,
      groups:
        Enum.map(Enum.group_by(runs, & &1.kind), fn {kind, rows} ->
          %{kind: kind, invocations: length(rows), sends: Enum.sum(Enum.map(rows, & &1.sends))}
        end)
    }
  end

  def shape(value) do
    cond do
      AL.Var.var?(value) -> :open
      is_list(value) -> %{kind: :list, prefix: prefix(value, 3)}
      true -> shallow(value)
    end
  end

  defp prefix(_, 0), do: []
  defp prefix([], _), do: []
  defp prefix([head | tail], count), do: [shallow(head) | prefix(tail, count - 1)]
  defp prefix(_tail, _), do: [:open_tail]

  def shallow(%AL.Goal.Compound{name: name, args: args}),
    do: %{compound: name, arity: length(args)}

  def shallow(value) when is_map(value), do: %{class: Map.get(value, :class, :map)}
  def shallow(value), do: if(AL.Var.var?(value), do: :open, else: value)

  def matched(nil, _clause), do: nil

  def matched(result, {identity, _, _, _, _, _}) do
    if active?(), do: Process.put({:boundary_match, match_key(result)}, identity)
    result
  end

  def match_key({_code, slots, store, _variants, _forwarded, head}), do: {slots, store, head}

  def snapshot({_id, code, _pc, slots, returns, store, pending}),
    do: {code, slots, returns, store, pending}

  def prepared(entry, matched) do
    if active?(),
      do:
        Process.put(
          {:boundary_entry, snapshot(entry)},
          Process.get({:boundary_match, match_key(matched)})
        )

    entry
  end

  def created(entries, kind, selector) do
    if active?() do
      for entry <- entries do
        identity = Process.get({:boundary_entry, snapshot(entry)})
        if identity == nil, do: raise("missing clause attribution")
        {id, seq, head, _operand} = identity
        key = {kind, selector, id, seq, inspect(head)}
        bump({:created, key})

        if Process.get({:boundary_choice, snapshot(entry)}) != nil,
          do: raise("ambiguous alternative snapshot")

        Process.put({:boundary_choice, snapshot(entry)}, key)
      end
    end

    entries
  end

  def resumed(entry) do
    if active?() do
      if key = Process.delete({:boundary_choice, snapshot(entry)}), do: bump({:resumed, key})
    end
  end
end

alias Bench.ParseBoundaryProfile, as: Profile

File.read!(Path.join([__DIR__, "..", "lib", "AL", "jam", "scan.ex"]))
|> Profile.patch!(
  "        output = Var.deref(store, output)",
  "        output = Var.deref(store, output)\n        Bench.ParseBoundaryProfile.scan_admission(selector, input, rest, output, store)"
)
|> Profile.patch!(
  "    if first != ?$ and",
  "    Bench.ParseBoundaryProfile.scan_prefix(plan, input)\n    if first != ?$ and"
)
|> Code.compile_string()

source = File.read!(Path.join([__DIR__, "..", "lib", "AL", "jam.ex"]))

source =
  source
  |> Profile.patch!(
    "          {:ok, callee_id, callee, targets} ->",
    "          {:ok, callee_id, callee, targets} ->\n            Bench.ParseBoundaryProfile.target(callee_id, method)"
  )
  |> Profile.patch!(
    "        call =\n          if destinations == [],",
    "        Bench.ParseBoundaryProfile.send(id, pc, operation, object, method, slots, store)\n        call =\n          if destinations == [],"
  )
  |> Profile.patch!("  defp match_clause(\n", """
    defp match_clause(clause, call, store, branch, outputs) do
      result = audited_match_clause(clause, call, store, branch, outputs)
      Bench.ParseBoundaryProfile.matched(result, clause)
    end
    defp audited_match_clause(
  """)
  |> Profile.patch!(
    "  defp entry(id, {code, slots, store, _variants, _forwarded, head}, returns) do",
    """
      defp entry(id, matched, returns) do
        Bench.ParseBoundaryProfile.prepared(audited_entry(id, matched, returns), matched)
      end
      defp audited_entry(id, {code, slots, store, _variants, _forwarded, head}, returns) do
    """
  )
  |> Profile.patch!(
    "{_code, _callee_slots, store, _variants, [_ | _] = forwarded, _head},",
    "{_code, _callee_slots, store, _variants, [_ | _] = forwarded, _head} = matched,"
  )
  |> Profile.patch!(
    "    {caller_id, caller_code, caller_pc, slots, returns, store, %{}}\n",
    "    Bench.ParseBoundaryProfile.prepared({caller_id, caller_code, caller_pc, slots, returns, store, %{}}, matched)\n"
  )
  |> Profile.patch!(
    "alternatives = Enum.map(alternatives, &with_pending(&1, pending))",
    "alternatives = Enum.map(alternatives, &with_pending(&1, pending)) |> Bench.ParseBoundaryProfile.created(:send, method)"
  )
  |> Profile.patch!(
    "alternatives = Enum.map(rest, &with_pending(entry(frame, &1, returns), pending))",
    "alternatives = Enum.map(rest, &with_pending(entry(frame, &1, returns), pending)) |> Bench.ParseBoundaryProfile.created(:next, elem(cursor, 0))"
  )

[prefix, rest] = String.split(source, "  defp resume_entry(", parts: 2)
[entry, suffix] = String.split(rest, "\n  defp loop(", parts: 2)

entry =
  entry
  |> Profile.patch!(
    "       do:\n         loop(",
    "       do:\n         (Bench.ParseBoundaryProfile.resumed({id, code, pc, slots, returns, store, pending}); loop("
  )
  |> Profile.patch!("           pending\n         )", "           pending\n         ))")

Code.compile_string(prefix <> "  defp resume_entry(" <> entry <> "\n  defp loop(" <> suffix)

Bench.Language.isolated(fn ->
  path =
    case System.argv() do
      [] -> Path.join(__DIR__, "fixtures/point.al")
      [path] -> path
    end

  program =
    Bench.Language.program("parse al_grammar (program Items) Source.", %{
      {:"$var", "Source"} => File.read!(path)
    })

  expected = Bench.Language.bindings(AL.eval(program))
  for _ <- 1..2, do: Bench.Language.bindings(AL.eval(program))

  samples =
    for _ <- 1..3 do
      Profile.reset()
      Process.put(:boundary_enabled, true)

      result =
        try do
          Bench.Language.bindings(AL.eval(program))
        after
          Process.put(:boundary_enabled, false)
        end

      if result != expected, do: raise("profile changed parse result")
      Profile.counts()
    end

  if length(Enum.uniq(samples)) != 1, do: raise("boundary counts differ between warm parses")
  counts = List.last(samples)

  sends =
    for {{:send, key}, count} <- counts,
        do: Map.put(Process.get({:boundary_sample, key}), :count, count)

  alternatives =
    for {{metric, {kind, selector, id, seq, head}}, count} <- counts,
        metric in [:created, :resumed],
        do: %{
          metric: metric,
          kind: kind,
          selector: selector,
          method: id,
          clause: seq,
          head: head,
          count: count
        }

  ids =
    Enum.uniq(
      Enum.map(alternatives, & &1.method) ++
        for({{:boundary_method, id}, _} <- Process.get(), do: id)
    )

  {:atomic, sources} =
    :mnesia.transaction(fn ->
      Map.new(ids, fn id ->
        rows = AL.JAM.Clauses.cached_scan_clauses(id, AL.Branch.head())

        clauses =
          Enum.map(rows, fn {:oapply, _, seq, head, body} ->
            forwarding =
              case AL.JAM.IR.Program.first(AL.JAM.IR.Program.lower(body)) do
                {:operation, %AL.JAM.IR{kind: :control, name: :next}, rest} ->
                  AL.JAM.IR.Program.first(rest) == :return

                _ ->
                  false
              end

            %{
              clause: seq,
              head: inspect(head, limit: :infinity),
              body: inspect(body, limit: :infinity),
              forwarding_only: forwarding
            }
          end)

        {id, clauses}
      end)
    end)

  alternatives =
    Enum.map(alternatives, fn alternative ->
      clause = Enum.find(sources[alternative.method], &(&1.clause == alternative.clause))
      Map.put(alternative, :forwarding_only, clause.forwarding_only)
    end)

  report = %{
    file: path,
    samples: 3,
    identical_samples: true,
    sends: Enum.sort_by(sends, &(-&1.count)),
    alternatives: Enum.sort_by(alternatives, &{&1.metric, -&1.count}),
    sources: sources,
    symbol_runs: Profile.symbol_runs(Enum.reverse(Process.get(:boundary_path, []))),
    scan_admission:
      for(
        {key, count} <- counts,
        elem(key, 0) in [:scan_admission, :scan_prefix],
        do: %{key: inspect(key), count: count}
      ),
    path: Enum.reverse(Process.get(:boundary_path, []))
  }

  IO.inspect(
    %{
      file: path,
      sends: Enum.sum(Enum.map(sends, & &1.count)),
      resumed: Enum.sum(for a <- alternatives, a.metric == :resumed, do: a.count),
      resumed_forwarding:
        Enum.sum(for a <- alternatives, a.metric == :resumed and a.forwarding_only, do: a.count),
      samples: 3,
      identical_samples: true
    },
    limit: :infinity
  )

  report
end)
