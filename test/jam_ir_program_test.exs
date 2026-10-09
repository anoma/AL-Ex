defmodule AL.JAM.IRProgramTest do
  use ExUnit.Case, async: true
  alias AL.Goal
  alias AL.JAM.IR
  alias AL.JAM.IR.{Dataflow, Program, Region}

  defp answers(program) do
    snapshot = program |> AL.JAM.compile() |> AL.JAM.with_store(%{})
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

    program = Program.lower([choice, %Goal.Eq{a: {:"$var", "Output"}, b: {:"$var", "Value"}}])
    assert {:choice, left, right, join} = program.blocks[program.entry].exit
    assert join in Program.successors(program.blocks[left])
    assert {:choice, _, _, ^join} = program.blocks[right].exit
    assert answers(program) == [:first, :first, :second]
  end

  test "an IR value rewrite compiles without returning to the AST" do
    program = Program.lower([%Goal.Eq{a: {:"$var", "Output"}, b: {:"$var", "Input"}}])
    program = Program.subst(program, %{{:"$var", "Input"} => :specialized})
    assert answers(program) == [:specialized]
    assert Program.variables(program) == MapSet.new([{:"$var", "Output"}])

    assert {[%AL.JAM.CompiledClause{code: code}], _} =
             AL.JAM.Compiler.compile([{:oapply, :ir_only, 0, [{:"$var", "Output"}], program}])

    assert tuple_size(code) == 1
  end

  test "inlined conditional regions keep their own condition return" do
    prefix =
      Program.lower([
        %Goal.Implies{
          condition: [%Goal.Eq{a: {:"$var", "Local"}, b: :chosen}],
          then: [%Goal.Eq{a: {:"$var", "Value"}, b: {:"$var", "Local"}}],
          otherwise: [%Goal.Eq{a: {:"$var", "Value"}, b: :wrong}]
        }
      ])

    suffix = Program.lower([%Goal.Eq{a: {:"$var", "Output"}, b: {:"$var", "Value"}}])
    assert answers(Program.concat(prefix, suffix)) == [:chosen]

    failing =
      Program.lower([
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
      Program.lower([
        %Goal.Send{object: :receiver, method: :selector, args: [{:"$var", "Output"}]},
        %Goal.Atom{term: {:"$var", "Output"}}
      ])

    assert {:call, %IR{kind: :send}, next} = program.blocks[program.entry].exit
    assert Map.has_key?(program.blocks, next)
    assert program.blocks[program.entry].failure == :backtrack
    assert program.blocks[program.entry].suspension == :resume
  end

  test "scoped code is a nested IR program and effects are conservative" do
    program =
      Program.lower([
        %Goal.Forall{
          condition: [%Goal.Pass{}],
          body: [%Goal.Eq{a: {:"$var", "Output"}, b: :value}]
        },
        %Goal.SetClass{object: :object, class: :class}
      ])

    assert {:execute, operation, _} = program.blocks[program.entry].exit
    assert %Program{} = operation.regions.condition
    assert %Program{} = operation.regions.body
    assert IR.effects(operation) == :scoped
    assert operation.retained_goals == []
    assert operation.fallback == []
    assert Program.any?(program, &(IR.effects(&1) == :write))
    refute Program.any?(program, &(&1.kind == :unsupported))
  end

  test "equal branch facts reach the join without losing duplicate answers" do
    program =
      Program.lower([
        %Goal.Or{
          or: [%Goal.Eq{a: {:"$var", "Tag"}, b: :same}],
          then: [%Goal.Eq{a: {:"$var", "Tag"}, b: :same}]
        },
        %Goal.Eq{a: {:"$var", "Output"}, b: {:"$var", "Tag"}}
      ])

    optimized = Dataflow.specialize(program, MapSet.new([{:"$var", "Output"}]))
    assert answers(optimized) == [:same, :same]
    refute MapSet.member?(Program.variables(optimized), {:"$var", "Tag"})
    assert {:choice, _, _, _} = optimized.blocks[optimized.entry].exit
  end

  test "conflicting branch facts retain the shared variable" do
    program =
      Program.lower([
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
      Program.lower([
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
      Program.lower([
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
      Program.lower([
        %Goal.Eq{a: {:"$var", "Dead"}, b: :unused},
        %Goal.Eq{a: {:"$var", "Value"}, b: :used},
        %Goal.Eq{a: {:"$var", "Output"}, b: {:"$var", "Value"}}
      ])

    {:jump, middle} = program.blocks[program.entry].exit
    {:jump, final} = program.blocks[middle].exit
    analysis = Dataflow.analyze(program, MapSet.new([{:"$var", "Output"}]), false)
    assert MapSet.member?(analysis.live.in[final], {:"$var", "Value"})
    refute MapSet.member?(analysis.live.in[program.entry], {:"$var", "Value"})
    refute MapSet.member?(analysis.live.out[program.entry], {:"$var", "Dead"})
  end

  test "effects on a failed alternative still invalidate dispatch assumptions" do
    program =
      Program.lower([
        %Goal.Or{
          or: [%Goal.SetClass{object: :object, class: :class}, %Goal.Fail{}],
          then: [%Goal.Pass{}]
        },
        %Goal.Eq{a: {:"$var", "Output"}, b: :value}
      ])

    {:choice, _, _, join} = program.blocks[program.entry].exit
    analysis = Dataflow.analyze(program, MapSet.new([{:"$var", "Output"}]))
    refute analysis.before[join].stable
    assert Program.any?(analysis.program, &(IR.effects(&1) == :write))
  end

  test "region compilation removes fresh shape and alias intermediates" do
    program =
      Program.lower([
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
      Program.lower([
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
      Program.lower([
        %Goal.Eq{a: {:"$var", "Sum"}, b: %Goal.Compound{name: :+, args: [{:"$var", "Input"}, 3]}},
        %Goal.Eq{a: {:"$var", "Input"}, b: 2},
        %Goal.Eq{a: {:"$var", "Output"}, b: {:"$var", "Sum"}}
      ])

    optimized = Region.compile(program, MapSet.new([{:"$var", "Output"}]))
    assert answers(optimized) == [5]
    assert MapSet.member?(Program.variables(optimized), {:"$var", "Sum"})
    analysis = Dataflow.analyze(program, MapSet.new([{:"$var", "Output"}]))
    assert analysis.inference[program.entry][0].suspension == :unknown
  end

  test "inference distinguishes fresh writes from caller-visible unification" do
    op = IR.operation(:direct, :eq, [{:"$var", "Value"}, 4])
    fresh = AL.JAM.IR.Inference.operation(op, MapSet.new())
    assert fresh.modes == [:fresh, :ground]
    assert fresh.determinism == :det
    assert fresh.suspension == :never
    caller = AL.JAM.IR.Inference.operation(op, MapSet.new([{:"$var", "Value"}]))
    assert caller.determinism == :unknown
    assert caller.binding == nil
    test = AL.JAM.IR.Inference.operation(IR.operation(:compare, :<, [1, 2]), MapSet.new())
    assert test.determinism == :semidet
    assert test.suspension == :never
  end

  test "region compilation preserves a caller's rejecting output and duplicate solutions" do
    program =
      Program.lower([
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
      Program.lower([
        %Goal.Or{
          or: [%Goal.Eq{a: {:"$var", "Capture"}, b: 1}],
          then: [%Goal.Eq{a: {:"$var", "Capture"}, b: 2}]
        },
        call
      ])

    assert answers(program) == [1, 2]

    aliased =
      Program.lower([
        %Goal.Eq{a: {:"$var", "Capture"}, b: [{:"$var", "Shared"}, {:"$var", "Shared"}]},
        %Goal.Eq{a: {:"$var", "Output"}, b: [1, 2]},
        call
      ])

    assert answers(aliased) == []

    accepted =
      Program.subst(
        Program.lower([
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

    assert AL.JAM.pending_goals(%AL.JAM.Frame{id: :test, code: code, slots: slots, store: %{}}) ==
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
      Program.lower([
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
      Program.lower([
        %Goal.Eq{a: {:"$var", "Args"}, b: [{:"$var", "Output"} | {:"$var", "Tail"}]},
        %Goal.Eq{a: {:"$var", "Tail"}, b: [[1, {:"$var", "Shared"}]]},
        call,
        %Goal.Eq{a: {:"$var", "Shared"}, b: 2}
      ])

    assert IR.Inference.operation(IR.lower(call), MapSet.new()).access == [
             :deep,
             :deep,
             :reference
           ]

    assert answers(program) == [[1, 2]]
  end

  test "callable matching completes an open argument tail" do
    call = %Goal.Call{head: [:value], body: [], args: [:value | {:"$var", "Output"}]}
    assert answers(Program.lower([call])) == [[]]
  end

  test "callable argument spines follow each backtracking alternative" do
    call = %Goal.Call{
      head: [{:"$var", "Arg"}, {:"$var", "Result"}],
      body: [%Goal.Eq{a: {:"$var", "Result"}, b: {:"$var", "Arg"}}],
      args: {:"$var", "Args"}
    }

    program =
      Program.lower([
        %Goal.Or{
          or: [%Goal.Eq{a: {:"$var", "Args"}, b: [:first, {:"$var", "Output"}]}],
          then: [%Goal.Eq{a: {:"$var", "Args"}, b: [:second, {:"$var", "Output"}]}]
        },
        call
      ])

    assert answers(program) == [:first, :second]
  end
end
