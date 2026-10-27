defmodule AL.JAM.IRProgramTest do
  alias AL.JAM.Instruction
  alias AL.JAM.IR.Normalize
  use ExUnit.Case, async: true
  alias AL.Goal
  alias AL.JAM.IR
  alias AL.JAM.IR.{Dataflow, Program, Region}

  defp answers(program) do
    snapshot = program |> AL.JAM.compile() |> AL.JAM.Frame.with_store(%{})
    collect(AL.JAM.resume(snapshot, AL.Branch.head(), 1000), [])
  end

  defp collect({:ok, store, _}, choices),
    do: [AL.Var.subst({:"$var", "Output"}, store) | remaining(choices)]

  defp collect({:answers, store, alternatives, _}, choices),
    do: [AL.Var.subst({:"$var", "Output"}, store) | remaining(alternatives ++ choices)]

  defp collect({:commit, snapshot, alternatives, _}, choices) do
    [_ | remaining] = Enum.drop_while(alternatives ++ choices, &(&1 != :implies_mark))
    collect(AL.JAM.resume(snapshot, AL.Branch.head(), 1000), remaining)
  end

  defp collect({:failed, _, _}, choices), do: remaining(choices)
  defp remaining([]), do: []
  defp remaining([:implies_mark | rest]), do: remaining(rest)

  defp remaining([choice | rest]),
    do: collect(AL.JAM.resume(choice, AL.Branch.head(), 1000), rest)

  test "reduce follows graph successors and visits shared nodes once" do
    program = %Program{
      entry: 0,
      nodes: %{
        0 => %Program.Choice{left: 7, right: 2, join: 5},
        7 => %Program.Node{instruction: :left, next: 5},
        2 => %Program.Node{instruction: :right, next: 5},
        5 => %Program.Node{instruction: :shared, next: 0},
        9 => %Program.Node{instruction: :unreachable, next: 9}
      }
    }

    assert Program.reduce(program, [], fn instruction, seen -> seen ++ [instruction] end) ==
             [:left, :shared, :right]
  end

  test "inlined body jumps to its continuation" do
    body = Normalize.lower([])
    continuation = Normalize.lower([:pass])
    program = Program.inline(body, continuation, :method)

    assert AL.JAM.IR.Assembler.emit(program, %{}) == [{:jump, 1, []}, :pass]

    assert Program.reduce(program, [], fn instruction, seen -> [instruction | seen] end) == [
             :pass
           ]
  end

  test "both inlined alternatives reach the caller continuation" do
    choice = %Goal.Or{
      or: [%Goal.Eq{a: {:"$var", "Value"}, b: :left}],
      then: [%Goal.Eq{a: {:"$var", "Value"}, b: :right}]
    }

    body = Normalize.lower([choice])
    continuation = Normalize.lower([%Goal.Eq{a: {:"$var", "Output"}, b: {:"$var", "Value"}}])

    assert body |> Program.inline(continuation, :method) |> answers() == [:left, :right]
  end

  test "choice code shares its continuation after both arms" do
    left = %Goal.Eq{a: {:"$var", "Value"}, b: :left}
    right = %Goal.Eq{a: {:"$var", "Value"}, b: :right}
    continuation = %Goal.Eq{a: {:"$var", "Output"}, b: {:"$var", "Value"}}
    goals = [%Goal.Or{or: [left], then: [right]}, continuation]
    {code, slots} = AL.JAM.IR.Assembler.compile(goals)

    assert {:try, alternative, _live} = elem(code, 0)
    assert {:jump, join, []} = elem(code, alternative - 1)
    assert alternative < join
    assert %Goal.Eq{} = AL.JAM.Goals.instruction(elem(code, join), slots)
    assert AL.JAM.Goals.instructions(code, 0, slots) == goals
    assert AL.JAM.Goals.instructions(code, 1, slots) == [left, continuation]

    frame = AL.JAM.compile(goals)
    assert frame.code == code
  end

  test "ordered alternatives share a continuation and preserve duplicate answers" do
    choice = %Goal.Or{
      or: [%Goal.Eq{a: {:"$var", "Value"}, b: :first}],
      then: [
        %Goal.Or{
          or: [%Goal.Eq{a: {:"$var", "Value"}, b: :first}],
          then: [%Goal.Eq{a: {:"$var", "Value"}, b: :second}]
        }
      ]
    }

    program = Normalize.lower([choice, %Goal.Eq{a: {:"$var", "Output"}, b: {:"$var", "Value"}}])
    assert %Program.Choice{left: left, right: right, join: join} = program.nodes[program.entry]
    assert join in Program.successors(program.nodes[left])
    assert %Program.Choice{join: ^join} = program.nodes[right]
    assert answers(program) == [:first, :first, :second]
  end

  test "an IR value rewrite compiles without returning to the AST" do
    program = Normalize.lower([%Goal.Eq{a: {:"$var", "Output"}, b: {:"$var", "Input"}}])
    program = Program.subst(program, %{{:"$var", "Input"} => :specialized})
    assert answers(program) == [:specialized]
    assert Program.variables(program) == MapSet.new([{:"$var", "Output"}])

    assert {[%AL.JAM.CompiledClause{code: code}], _} =
             AL.JAM.Compiler.compile([{:oapply, :ir_only, 0, [{:"$var", "Output"}], program}])

    assert tuple_size(code) == 1
  end

  test "inlined conditional regions keep their own condition return" do
    prefix =
      Normalize.lower([
        %Goal.Implies{
          condition: [%Goal.Eq{a: {:"$var", "Local"}, b: :chosen}],
          then: [%Goal.Eq{a: {:"$var", "Value"}, b: {:"$var", "Local"}}],
          otherwise: [%Goal.Eq{a: {:"$var", "Value"}, b: :wrong}]
        }
      ])

    suffix = Normalize.lower([%Goal.Eq{a: {:"$var", "Output"}, b: {:"$var", "Value"}}])
    assert answers(Program.concat(prefix, suffix)) == [:chosen]

    failing =
      Normalize.lower([
        %Goal.Implies{
          condition: [%Goal.Fail{}],
          then: [%Goal.Fail{}],
          otherwise: [%Goal.Eq{a: {:"$var", "Value"}, b: :fallback}]
        }
      ])

    assert answers(Program.concat(failing, suffix)) == [:fallback]
  end

  test "calls expose continuations" do
    program =
      Normalize.lower([
        %Goal.Send{object: :receiver, method: :selector, args: [{:"$var", "Output"}]},
        %Goal.Atom{term: {:"$var", "Output"}}
      ])

    assert %Program.Node{instruction: {:send, nil, _, _, _}, next: next} =
             program.nodes[program.entry]

    assert Map.has_key?(program.nodes, next)
  end

  test "scoped code is a nested IR program and effects are conservative" do
    program =
      Normalize.lower([
        %Goal.Forall{
          condition: [%Goal.Pass{}],
          body: [%Goal.Eq{a: {:"$var", "Output"}, b: :value}]
        },
        %Goal.SetClass{object: :object, class: :class}
      ])

    assert %Program.Node{instruction: operation} = program.nodes[program.entry]
    assert {:forall, nil, %Program{}, nil, %Program{}} = operation
    assert Instruction.effects(operation) == :scoped
    assert Program.any?(program, &(Instruction.effects(&1) == :write))
    assert Program.any?(program, &match?({:mutation, :set_class, _}, &1))
  end

  test "equal branch facts reach the join without losing duplicate answers" do
    program =
      Normalize.lower([
        %Goal.Or{
          or: [%Goal.Eq{a: {:"$var", "Tag"}, b: :same}],
          then: [%Goal.Eq{a: {:"$var", "Tag"}, b: :same}]
        },
        %Goal.Eq{a: {:"$var", "Output"}, b: {:"$var", "Tag"}}
      ])

    optimized = Dataflow.specialize(program, MapSet.new([{:"$var", "Output"}]))
    assert answers(optimized) == [:same, :same]
    refute MapSet.member?(Program.variables(optimized), {:"$var", "Tag"})
    assert %Program.Choice{} = optimized.nodes[optimized.entry]
  end

  test "conflicting branch facts retain the shared variable" do
    program =
      Normalize.lower([
        %Goal.Or{
          or: [%Goal.Eq{a: {:"$var", "Tag"}, b: :first}],
          then: [%Goal.Eq{a: {:"$var", "Tag"}, b: :second}]
        },
        %Goal.Eq{a: {:"$var", "Output"}, b: {:"$var", "Tag"}}
      ])

    optimized = Dataflow.specialize(program, MapSet.new([{:"$var", "Output"}]))
    assert answers(optimized) == [:first, :second]
    assert MapSet.member?(Program.variables(optimized), {:"$var", "Tag"})
  end

  test "condition facts do not leak into the otherwise branch" do
    program =
      Normalize.lower([
        %Goal.Implies{
          condition: [%Goal.Eq{a: {:"$var", "Tag"}, b: :wrong}, %Goal.Fail{}],
          then: [%Goal.Eq{a: {:"$var", "Output"}, b: :wrong}],
          otherwise: [
            %Goal.Eq{a: {:"$var", "Tag"}, b: :right},
            %Goal.Eq{a: {:"$var", "Output"}, b: {:"$var", "Tag"}}
          ]
        }
      ])

    assert answers(Dataflow.specialize(program, MapSet.new([{:"$var", "Output"}]))) == [:right]
  end

  test "caller-visible bindings survive propagation and dead binding elimination" do
    program =
      Normalize.lower([
        %Goal.Or{
          or: [%Goal.Eq{a: {:"$var", "Output"}, b: :first}],
          then: [%Goal.Eq{a: {:"$var", "Output"}, b: :second}]
        }
      ])

    assert answers(Dataflow.specialize(program, MapSet.new([{:"$var", "Output"}]))) == [
             :first,
             :second
           ]
  end

  test "liveness excludes a later fresh definition from a region interface" do
    program =
      Normalize.lower([
        %Goal.Eq{a: {:"$var", "Dead"}, b: :unused},
        %Goal.Eq{a: {:"$var", "Value"}, b: :used},
        %Goal.Eq{a: {:"$var", "Output"}, b: {:"$var", "Value"}}
      ])

    %Program.Node{next: middle} = program.nodes[program.entry]
    %Program.Node{next: final} = program.nodes[middle]
    analysis = Dataflow.analyze(program, MapSet.new([{:"$var", "Output"}]), false)
    assert MapSet.member?(analysis.live.in[final], {:"$var", "Value"})
    refute MapSet.member?(analysis.live.in[program.entry], {:"$var", "Value"})
    refute MapSet.member?(analysis.live.out[program.entry], {:"$var", "Dead"})
  end

  test "effects on a failed alternative still invalidate dispatch assumptions" do
    program =
      Normalize.lower([
        %Goal.Or{
          or: [%Goal.SetClass{object: :object, class: :class}, %Goal.Fail{}],
          then: [%Goal.Pass{}]
        },
        %Goal.Eq{a: {:"$var", "Output"}, b: :value}
      ])

    %Program.Choice{join: join} = program.nodes[program.entry]
    analysis = Dataflow.analyze(program, MapSet.new([{:"$var", "Output"}]))
    refute analysis.before[join].stable
    assert Program.any?(analysis.program, &(Instruction.effects(&1) == :write))
  end

  test "region compilation removes fresh shape and alias intermediates" do
    program =
      Normalize.lower([
        %Goal.Eq{a: {:"$var", "Shape"}, b: [:tag, {:"$var", "Input"}]},
        %Goal.Eq{a: {:"$var", "Alias"}, b: {:"$var", "Shape"}},
        %Goal.Eq{a: {:"$var", "Output"}, b: {:"$var", "Alias"}}
      ])

    interface = MapSet.new([{:"$var", "Input"}, {:"$var", "Output"}])
    optimized = Region.compile(program, interface)
    refute MapSet.member?(Program.variables(optimized), {:"$var", "Shape"})
    refute MapSet.member?(Program.variables(optimized), {:"$var", "Alias"})
    assert answers(Program.subst(optimized, %{{:"$var", "Input"} => 42})) == [[:tag, 42]]

    assert {[%AL.JAM.CompiledClause{code: code}], _} =
             AL.JAM.Compiler.compile([
               {:oapply, :region, 0, [{:"$var", "Input"}, {:"$var", "Output"}], program}
             ])

    assert tuple_size(code) == 1
  end

  test "ground arithmetic is evaluated before propagating its result" do
    program =
      Normalize.lower([
        %Goal.Eq{a: {:"$var", "Sum"}, b: %Goal.Compound{name: :+, args: [2, 3]}},
        %Goal.Eq{a: {:"$var", "Output"}, b: [{:"$var", "Sum"}]}
      ])

    assert answers(program) == [[5]]
    optimized = Region.compile(program, MapSet.new([{:"$var", "Output"}]))
    assert answers(optimized) == [[5]]
    refute MapSet.member?(Program.variables(optimized), {:"$var", "Sum"})
  end

  test "unresolved arithmetic retains its constraint and region boundary" do
    program =
      Normalize.lower([
        %Goal.Eq{a: {:"$var", "Sum"}, b: %Goal.Compound{name: :+, args: [{:"$var", "Input"}, 3]}},
        %Goal.Eq{a: {:"$var", "Input"}, b: 2},
        %Goal.Eq{a: {:"$var", "Output"}, b: {:"$var", "Sum"}}
      ])

    optimized = Region.compile(program, MapSet.new([{:"$var", "Output"}]))
    assert answers(optimized) == [5]
    assert MapSet.member?(Program.variables(optimized), {:"$var", "Sum"})
    analysis = Dataflow.analyze(program, MapSet.new([{:"$var", "Output"}]))
    assert analysis.inference[program.entry].suspension == :unknown
  end

  test "inference distinguishes fresh writes from caller-visible unification" do
    op = {:eq, {:"$var", "Value"}, 4}
    fresh = AL.JAM.IR.Inference.operation(op, MapSet.new())
    assert fresh.modes == [:fresh, :ground]
    assert fresh.determinism == :det
    assert fresh.suspension == :never
    caller = AL.JAM.IR.Inference.operation(op, MapSet.new([{:"$var", "Value"}]))
    assert caller.determinism == :unknown
    assert caller.binding == nil
    test = AL.JAM.IR.Inference.operation({:compare, :<, 1, 2}, MapSet.new())
    assert test.determinism == :semidet
    assert test.suspension == :never
  end

  test "region compilation preserves a caller's rejecting output and duplicate solutions" do
    program =
      Normalize.lower([
        %Goal.Or{or: [%Goal.Pass{}], then: [%Goal.Pass{}]},
        %Goal.Eq{a: {:"$var", "Temporary"}, b: [:value]},
        %Goal.Eq{a: {:"$var", "Output"}, b: {:"$var", "Temporary"}}
      ])

    optimized = Region.compile(program, MapSet.new([{:"$var", "Output"}]))
    assert answers(optimized) == [[:value], [:value]]
    assert answers(Program.subst(optimized, %{{:"$var", "Output"} => [:other]})) == []
  end

  test "callable compilation shares renamed code while preserving alias and literal differences" do
    AL.ResolutionCache.with_transaction_cache(fn ->
      branch = AL.Branch.head()

      compile = fn a, b, value ->
        {compiled, _captures} =
          AL.JAM.Compiler.fetch_callable(
            [a, b],
            [
              %Goal.Compound{name: :send, args: [a, :selector, [b, value]]}
            ],
            branch
          )

        compiled
      end

      first = compile.({:"$var", "First"}, {:"$var", "Second"}, 1)
      assert first === compile.({:"$var", "Receiver"}, {:"$var", "Result"}, 1)
      refute first === compile.({:"$var", "Same"}, {:"$var", "Same"}, 1)
      refute first === compile.({:"$var", "Receiver"}, {:"$var", "Result"}, 2)
    end)
  end

  test "runtime capture values and variable identities share one callable body" do
    AL.ResolutionCache.with_transaction_cache(fn ->
      branch = AL.Branch.head()
      body = [%Goal.Compound{name: :=, args: [{:"$var", "Argument"}, {:"$var", "Captured"}]}]
      site = make_ref()

      {first, env1, targets} =
        AL.JAM.Callable.fetch(
          %{},
          site,
          [{:"$var", "Argument"}],
          body,
          %{{:"$var", "Captured"} => 1},
          branch
        )

      {second, env2, _} =
        AL.JAM.Callable.fetch(
          targets,
          site,
          [{:"$var", "Argument"}],
          body,
          %{{:"$var", "Captured"} => 2},
          branch
        )

      assert first === second
      assert List.last(env1) == 1
      assert List.last(env2) == 2

      renamed =
        AL.Term.map(body, fn
          {:"$var", "Argument"} -> {:"$var", "OtherArgument"}
          {:"$var", "Captured"} -> {:"$var", "OtherCapture"}
          value -> value
        end)

      {third, env3, _} =
        AL.JAM.Callable.fetch(
          targets,
          site,
          [{:"$var", "OtherArgument"}],
          renamed,
          %{{:"$var", "OtherCapture"} => [:different, :shape]},
          branch
        )

      assert first === third
      assert List.last(env3) == [:different, :shape]
    end)
  end

  test "callable environments follow backtracking and retain captured aliases" do
    call = %Goal.Call{
      head: [{:"$var", "Argument"}],
      body: [%Goal.Compound{name: :=, args: [{:"$var", "Argument"}, {:"$var", "Capture"}]}],
      args: [{:"$var", "Output"}]
    }

    program =
      Normalize.lower([
        %Goal.Or{
          or: [%Goal.Eq{a: {:"$var", "Capture"}, b: 1}],
          then: [%Goal.Eq{a: {:"$var", "Capture"}, b: 2}]
        },
        call
      ])

    assert answers(program) == [1, 2]

    aliased =
      Normalize.lower([
        %Goal.Eq{a: {:"$var", "Capture"}, b: [{:"$var", "Shared"}, {:"$var", "Shared"}]},
        %Goal.Eq{a: {:"$var", "Output"}, b: [1, 2]},
        call
      ])

    assert answers(aliased) == []

    accepted =
      Program.subst(
        Normalize.lower([
          %Goal.Eq{a: {:"$var", "Capture"}, b: [{:"$var", "Shared"}, {:"$var", "Shared"}]},
          call
        ]),
        %{{:"$var", "Output"} => [3, 3]}
      )

    assert length(answers(accepted)) == 1
  end

  test "static callable sites carry code and fixed capture locations" do
    body = [%Goal.Compound{name: :=, args: [{:"$var", "Argument"}, {:"$var", "Capture"}]}]
    goal = %Goal.Call{head: [{:"$var", "Argument"}], body: body, args: [{:"$var", "Output"}]}
    {code, slots} = AL.JAM.IR.Assembler.compile([goal])
    assert {{:call, _, _, {:compiled_callable, {:constant, template}, _, _}, _}} = code
    assert %AL.JAM.Callable.Template{capture_slots: [0, 1]} = template

    assert AL.JAM.Frame.pending_goals(%AL.JAM.Frame{
             id: :test,
             code: code,
             slots: slots,
             store: %{}
           }) ==
             [goal]

    for value <- [1, [:different, :shape], %{name: :value}] do
      snapshot = %AL.JAM.Frame{
        id: :test,
        code: code,
        slots: slots,
        store: %{{:"$var", "Capture"} => value}
      }

      assert {:ok, store, _} = AL.JAM.resume(snapshot, AL.Branch.head(), 100)
      assert AL.Var.subst({:"$var", "Output"}, store) == value
    end
  end

  test "dynamic callable bodies remain late bound across alternatives" do
    first = [%Goal.Compound{name: :=, args: [{:"$var", "Argument"}, :first]}]
    second = [%Goal.Compound{name: :=, args: [{:"$var", "Argument"}, :second]}]

    call = %Goal.Call{
      head: [{:"$var", "Argument"}],
      body: {:"$var", "Body"},
      args: [{:"$var", "Output"}]
    }

    {code, _} = AL.JAM.IR.Assembler.compile([call])
    assert {{:call, _, _, {:register, _}, _}} = code

    program =
      Normalize.lower([
        %Goal.Or{
          or: [%Goal.Eq{a: {:"$var", "Body"}, b: first}],
          then: [%Goal.Eq{a: {:"$var", "Body"}, b: second}]
        },
        call
      ])

    assert answers(program) == [:first, :second]
  end

  test "a static callable preserves partially bound capture aliases" do
    body = [%Goal.Compound{name: :=, args: [{:"$var", "Argument"}, {:"$var", "Capture"}]}]

    {code, slots} =
      AL.JAM.IR.Assembler.compile([
        %Goal.Call{head: [{:"$var", "Argument"}], body: body, args: [{:"$var", "Output"}]}
      ])

    for value <- [1, 2] do
      store = %{
        {:"$var", "Capture"} => [{:"$var", "Shared"}, {:"$var", "Shared"}],
        {:"$var", "Output"} => [value, value]
      }

      assert {:ok, _, _} =
               AL.JAM.resume(
                 %AL.JAM.Frame{id: :test, code: code, slots: slots, store: store},
                 AL.Branch.head(),
                 100
               )
    end

    store = %{
      {:"$var", "Capture"} => [{:"$var", "Shared"}, {:"$var", "Shared"}],
      {:"$var", "Output"} => [1, 2]
    }

    assert {:failed, _, _} =
             AL.JAM.resume(
               %AL.JAM.Frame{id: :test, code: code, slots: slots, store: store},
               AL.Branch.head(),
               100
             )
  end

  test "runtime-supplied goals and primitive selectors use dynamic source compilation" do
    call = %Goal.Call{
      head: [{:"$var", "Argument"}],
      body: [{:"$var", "Goal"}],
      args: [{:"$var", "Output"}]
    }

    {code, slots} = AL.JAM.IR.Assembler.compile([call])
    refute match?({{:call, _, _, {:compiled_callable, _, _, _}, _}}, code)

    for value <- [:first, :second] do
      goal = %Goal.Compound{name: :=, args: [{:"$var", "Argument"}, value]}

      snapshot = %AL.JAM.Frame{
        id: :test,
        code: code,
        slots: slots,
        store: %{{:"$var", "Goal"} => goal}
      }

      assert {:ok, store, _} = AL.JAM.resume(snapshot, AL.Branch.head(), 100)
      assert AL.Var.subst({:"$var", "Output"}, store) == value
    end

    selected = %Goal.Call{
      head: [{:"$var", "Argument"}],
      body: [%Goal.Compound{name: {:"$var", "Selector"}, args: [{:"$var", "Argument"}]}],
      args: [:value]
    }

    {code, slots} = AL.JAM.IR.Assembler.compile([selected])

    snapshot = %AL.JAM.Frame{
      id: :test,
      code: code,
      slots: slots,
      store: %{{:"$var", "Selector"} => :atom}
    }

    assert {:ok, _, _} = AL.JAM.resume(snapshot, AL.Branch.head(), 100)
  end

  test "callable arguments follow bound spines while retaining nested aliases" do
    call = %Goal.Call{
      head: [{:"$var", "Arg"}, {:"$var", "Arg"}],
      body: [],
      args: {:"$var", "Args"}
    }

    program =
      Normalize.lower([
        %Goal.Eq{a: {:"$var", "Args"}, b: [{:"$var", "Output"} | {:"$var", "Tail"}]},
        %Goal.Eq{a: {:"$var", "Tail"}, b: [[1, {:"$var", "Shared"}]]},
        call,
        %Goal.Eq{a: {:"$var", "Shared"}, b: 2}
      ])

    assert IR.Inference.operation(Normalize.instruction(call), MapSet.new()).access == [
             :deep,
             :deep,
             :reference
           ]

    assert answers(program) == [[1, 2]]
  end

  test "callable matching completes an open argument tail" do
    call = %Goal.Call{head: [:value], body: [], args: [:value | {:"$var", "Output"}]}
    assert answers(Normalize.lower([call])) == [[]]
  end

  test "callable argument spines follow each backtracking alternative" do
    call = %Goal.Call{
      head: [{:"$var", "Arg"}, {:"$var", "Result"}],
      body: [%Goal.Eq{a: {:"$var", "Result"}, b: {:"$var", "Arg"}}],
      args: {:"$var", "Args"}
    }

    program =
      Normalize.lower([
        %Goal.Or{
          or: [%Goal.Eq{a: {:"$var", "Args"}, b: [:first, {:"$var", "Output"}]}],
          then: [%Goal.Eq{a: {:"$var", "Args"}, b: [:second, {:"$var", "Output"}]}]
        },
        call
      ])

    assert answers(program) == [:first, :second]
  end
end
