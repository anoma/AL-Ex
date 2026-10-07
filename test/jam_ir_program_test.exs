defmodule AL.JAM.IRProgramTest do
  use ExUnit.Case, async: true
  alias AL.Goal
  alias AL.JAM.IR
  alias AL.JAM.IR.{Dataflow, Program, Region}

  defp answers(program) do
    snapshot = program |> AL.JAM.query() |> AL.JAM.with_store(%{})
    collect(AL.JAM.resume(snapshot, AL.Branch.head(), 1000), [])
  end

  defp collect({:ok, store, _}, choices),
    do: [AL.Var.subst(:"$Output", store) | remaining(choices)]

  defp collect({:answers, store, alternatives, _}, choices),
    do: [AL.Var.subst(:"$Output", store) | remaining(alternatives ++ choices)]

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
      or: [%Goal.Eq{a: :"$Value", b: :first}],
      then: [
        %Goal.Or{
          or: [%Goal.Eq{a: :"$Value", b: :first}],
          then: [%Goal.Eq{a: :"$Value", b: :second}]
        }
      ]
    }

    program = Program.lower([choice, %Goal.Eq{a: :"$Output", b: :"$Value"}])
    assert {:choice, left, right, join} = program.blocks[program.entry].exit
    assert join in Program.successors(program.blocks[left])
    assert {:choice, _, _, ^join} = program.blocks[right].exit
    assert answers(program) == [:first, :first, :second]
  end

  test "an IR value rewrite compiles without returning to the AST" do
    program = Program.lower([%Goal.Eq{a: :"$Output", b: :"$Input"}])
    program = Program.subst(program, %{:"$Input" => :specialized})
    assert answers(program) == [:specialized]
    assert Program.variables(program) == MapSet.new([:"$Output"])

    assert {[{_, _, _, _, code, _}], _} =
             AL.JAM.Compiler.compile([{:oapply, :ir_only, 0, [:"$Output"], program}])

    assert tuple_size(code) == 1
  end

  test "inlined conditional regions keep their own condition return" do
    prefix =
      Program.lower([
        %Goal.Implies{
          condition: [%Goal.Eq{a: :"$Local", b: :chosen}],
          then: [%Goal.Eq{a: :"$Value", b: :"$Local"}],
          otherwise: [%Goal.Eq{a: :"$Value", b: :wrong}]
        }
      ])

    suffix = Program.lower([%Goal.Eq{a: :"$Output", b: :"$Value"}])
    assert answers(Program.concat(prefix, suffix)) == [:chosen]

    failing =
      Program.lower([
        %Goal.Implies{
          condition: [%Goal.Fail{}],
          then: [%Goal.Fail{}],
          otherwise: [%Goal.Eq{a: :"$Value", b: :fallback}]
        }
      ])

    assert answers(Program.concat(failing, suffix)) == [:fallback]
  end

  test "calls expose continuations and a selected region exposes its outgoing edge" do
    program =
      Program.lower([
        %Goal.Send{object: :receiver, method: :selector, args: [:"$Output"]},
        %Goal.Atom{term: :"$Output"}
      ])

    assert {:call, %IR{kind: :send}, next} = program.blocks[program.entry].exit
    region = Region.select(program, program.entry, [program.entry])
    assert region.exits == [{program.entry, next}]
    assert MapSet.member?(region.outputs, :"$Output")
    assert program.blocks[program.entry].failure == :backtrack
    assert program.blocks[program.entry].suspension == :resume
  end

  test "scoped code is a nested IR program and effects are conservative" do
    program =
      Program.lower([
        %Goal.Forall{condition: [%Goal.Pass{}], body: [%Goal.Eq{a: :"$Output", b: :value}]},
        %Goal.SetClass{object: :object, class: :class}
      ])

    assert {:execute, operation, _} = program.blocks[program.entry].exit
    assert %Program{} = operation.regions.condition
    assert %Program{} = operation.regions.body
    assert IR.effects(operation) == :scoped
    assert is_nil(operation.source)
    assert Program.any?(program, &(IR.effects(&1) == :write))
    refute Program.any?(program, &(&1.kind == :unsupported))
  end

  test "equal branch facts reach the join without losing duplicate answers" do
    program =
      Program.lower([
        %Goal.Or{or: [%Goal.Eq{a: :"$Tag", b: :same}], then: [%Goal.Eq{a: :"$Tag", b: :same}]},
        %Goal.Eq{a: :"$Output", b: :"$Tag"}
      ])

    optimized = Dataflow.specialize(program, MapSet.new([:"$Output"]))
    assert answers(optimized) == [:same, :same]
    refute MapSet.member?(Program.variables(optimized), :"$Tag")
    assert {:choice, _, _, _} = optimized.blocks[optimized.entry].exit
  end

  test "conflicting branch facts retain the shared variable" do
    program =
      Program.lower([
        %Goal.Or{or: [%Goal.Eq{a: :"$Tag", b: :first}], then: [%Goal.Eq{a: :"$Tag", b: :second}]},
        %Goal.Eq{a: :"$Output", b: :"$Tag"}
      ])

    optimized = Dataflow.specialize(program, MapSet.new([:"$Output"]))
    assert answers(optimized) == [:first, :second]
    assert MapSet.member?(Program.variables(optimized), :"$Tag")
  end

  test "condition facts do not leak into the otherwise branch" do
    program =
      Program.lower([
        %Goal.Implies{
          condition: [%Goal.Eq{a: :"$Tag", b: :wrong}, %Goal.Fail{}],
          then: [%Goal.Eq{a: :"$Output", b: :wrong}],
          otherwise: [%Goal.Eq{a: :"$Tag", b: :right}, %Goal.Eq{a: :"$Output", b: :"$Tag"}]
        }
      ])

    assert answers(Dataflow.specialize(program, MapSet.new([:"$Output"]))) == [:right]
  end

  test "caller-visible bindings survive propagation and dead binding elimination" do
    program =
      Program.lower([
        %Goal.Or{
          or: [%Goal.Eq{a: :"$Output", b: :first}],
          then: [%Goal.Eq{a: :"$Output", b: :second}]
        }
      ])

    assert answers(Dataflow.specialize(program, MapSet.new([:"$Output"]))) == [:first, :second]
  end

  test "liveness excludes a later fresh definition from a region interface" do
    program =
      Program.lower([
        %Goal.Eq{a: :"$Dead", b: :unused},
        %Goal.Eq{a: :"$Value", b: :used},
        %Goal.Eq{a: :"$Output", b: :"$Value"}
      ])

    {:jump, middle} = program.blocks[program.entry].exit
    {:jump, final} = program.blocks[middle].exit
    region = Region.select(program, program.entry, [program.entry], MapSet.new([:"$Output"]))
    refute MapSet.member?(region.inputs, :"$Value")
    refute MapSet.member?(region.outputs, :"$Dead")
    analysis = Dataflow.analyze(program, MapSet.new([:"$Output"]), false)
    assert MapSet.member?(analysis.live.in[final], :"$Value")
    assert region.outputs == MapSet.new([:"$Output"])
  end

  test "effects on a failed alternative still invalidate dispatch assumptions" do
    program =
      Program.lower([
        %Goal.Or{
          or: [%Goal.SetClass{object: :object, class: :class}, %Goal.Fail{}],
          then: [%Goal.Pass{}]
        },
        %Goal.Eq{a: :"$Output", b: :value}
      ])

    {:choice, _, _, join} = program.blocks[program.entry].exit
    analysis = Dataflow.analyze(program, MapSet.new([:"$Output"]))
    refute analysis.before[join].stable
    assert Program.any?(analysis.program, &(IR.effects(&1) == :write))
  end

  test "region compilation removes fresh shape and alias intermediates" do
    program =
      Program.lower([
        %Goal.Eq{a: :"$Shape", b: [:tag, :"$Input"]},
        %Goal.Eq{a: :"$Alias", b: :"$Shape"},
        %Goal.Eq{a: :"$Output", b: :"$Alias"}
      ])

    interface = MapSet.new([:"$Input", :"$Output"])
    optimized = Region.compile(program, interface)
    refute MapSet.member?(Program.variables(optimized), :"$Shape")
    refute MapSet.member?(Program.variables(optimized), :"$Alias")
    assert answers(Program.subst(optimized, %{:"$Input" => 42})) == [[:tag, 42]]

    assert {[{_, _, _, _, code, _}], _} =
             AL.JAM.Compiler.compile([
               {:oapply, :region, 0, [:"$Input", :"$Output"], program}
             ])

    assert tuple_size(code) == 1
  end

  test "ground arithmetic is evaluated before propagating its result" do
    program =
      Program.lower([
        %Goal.Eq{a: :"$Sum", b: %Goal.Compound{name: :+, args: [2, 3]}},
        %Goal.Eq{a: :"$Output", b: [:"$Sum"]}
      ])

    assert answers(program) == [[5]]
    optimized = Region.compile(program, MapSet.new([:"$Output"]))
    assert answers(optimized) == [[5]]
    refute MapSet.member?(Program.variables(optimized), :"$Sum")
  end

  test "unresolved arithmetic retains its constraint and region boundary" do
    program =
      Program.lower([
        %Goal.Eq{a: :"$Sum", b: %Goal.Compound{name: :+, args: [:"$Input", 3]}},
        %Goal.Eq{a: :"$Input", b: 2},
        %Goal.Eq{a: :"$Output", b: :"$Sum"}
      ])

    optimized = Region.compile(program, MapSet.new([:"$Output"]))
    assert answers(optimized) == [5]
    assert MapSet.member?(Program.variables(optimized), :"$Sum")
    analysis = Dataflow.analyze(program, MapSet.new([:"$Output"]))
    assert analysis.inference[program.entry][0].suspension == :unknown
  end

  test "inference distinguishes fresh writes from caller-visible unification" do
    op = IR.operation(:direct, :eq, [:"$Value", 4])
    fresh = AL.JAM.IR.Inference.operation(op, MapSet.new())
    assert fresh.modes == [:fresh, :ground]
    assert fresh.determinism == :det
    assert fresh.suspension == :never
    caller = AL.JAM.IR.Inference.operation(op, MapSet.new([:"$Value"]))
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
        %Goal.Eq{a: :"$Temporary", b: [:value]},
        %Goal.Eq{a: :"$Output", b: :"$Temporary"}
      ])

    optimized = Region.compile(program, MapSet.new([:"$Output"]))
    assert answers(optimized) == [[:value], [:value]]
    assert answers(Program.subst(optimized, %{:"$Output" => [:other]})) == []
  end

  test "a selected region exposes its inferred execution contract" do
    program =
      Program.lower([
        %Goal.Eq{a: :"$Local", b: 4},
        %Goal.Compare{op: :<, a: 1, b: 2}
      ])

    region = Region.select(program, program.entry, Program.reachable(program))
    assert region.inference.determinism == :semidet
    assert region.inference.suspension == :never

    program =
      Program.lower([
        %Goal.Send{object: :receiver, method: :selector, args: []}
      ])

    region = Region.select(program, program.entry, Program.reachable(program))
    assert region.inference.determinism == :unknown
    assert region.inference.suspension == :unknown
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

      first = compile.(:"$First", :"$Second", 1)
      assert first === compile.(:"$Receiver", :"$Result", 1)
      refute first === compile.(:"$Same", :"$Same", 1)
      refute first === compile.(:"$Receiver", :"$Result", 2)
    end)
  end

  test "runtime capture values and variable identities share one callable body" do
    AL.ResolutionCache.with_transaction_cache(fn ->
      branch = AL.Branch.head()
      body = [%Goal.Compound{name: :=, args: [:"$Argument", :"$Captured"]}]
      site = make_ref()

      {first, env1, targets} =
        AL.JAM.Callable.fetch(%{}, site, [:"$Argument"], body, %{:"$Captured" => 1}, branch)

      {second, env2, _} =
        AL.JAM.Callable.fetch(targets, site, [:"$Argument"], body, %{:"$Captured" => 2}, branch)

      assert first === second
      assert List.last(env1) == 1
      assert List.last(env2) == 2

      renamed =
        AL.Goal.map(body, fn
          :"$Argument" -> :"$OtherArgument"
          :"$Captured" -> :"$OtherCapture"
          value -> value
        end)

      {third, env3, _} =
        AL.JAM.Callable.fetch(
          targets,
          site,
          [:"$OtherArgument"],
          renamed,
          %{:"$OtherCapture" => [:different, :shape]},
          branch
        )

      assert first === third
      assert List.last(env3) == [:different, :shape]
    end)
  end

  test "callable environments follow backtracking and retain captured aliases" do
    call = %Goal.Call{
      head: [:"$Argument"],
      body: [%Goal.Compound{name: :=, args: [:"$Argument", :"$Capture"]}],
      args: [:"$Output"]
    }

    program =
      Program.lower([
        %Goal.Or{or: [%Goal.Eq{a: :"$Capture", b: 1}], then: [%Goal.Eq{a: :"$Capture", b: 2}]},
        call
      ])

    assert answers(program) == [1, 2]

    aliased =
      Program.lower([
        %Goal.Eq{a: :"$Capture", b: [:"$Shared", :"$Shared"]},
        %Goal.Eq{a: :"$Output", b: [1, 2]},
        call
      ])

    assert answers(aliased) == []

    accepted =
      Program.subst(
        Program.lower([
          %Goal.Eq{a: :"$Capture", b: [:"$Shared", :"$Shared"]},
          call
        ]),
        %{:"$Output" => [3, 3]}
      )

    assert length(answers(accepted)) == 1
  end

  test "static callable sites carry code and fixed capture locations" do
    body = [%Goal.Compound{name: :=, args: [:"$Argument", :"$Capture"]}]
    goal = %Goal.Call{head: [:"$Argument"], body: body, args: [:"$Output"]}
    {code, slots} = AL.JAM.Compiler.runtime([goal])
    assert {{:call, _, _, {:compiled_callable, {:constant, template}, _, _}, _}} = code
    assert %AL.JAM.Callable.Template{capture_slots: [0, 1]} = template
    assert AL.JAM.pending_goals({:test, code, 0, slots, [], %{}, %{}}) == [goal]

    for value <- [1, [:different, :shape], %{name: :value}] do
      snapshot = {:test, code, 0, slots, [], %{:"$Capture" => value}, %{}}
      assert {:ok, store, _} = AL.JAM.resume(snapshot, AL.Branch.head(), 100)
      assert AL.Var.subst(:"$Output", store) == value
    end
  end

  test "dynamic callable bodies remain late bound across alternatives" do
    first = [%Goal.Compound{name: :=, args: [:"$Argument", :first]}]
    second = [%Goal.Compound{name: :=, args: [:"$Argument", :second]}]
    call = %Goal.Call{head: [:"$Argument"], body: :"$Body", args: [:"$Output"]}
    {code, _} = AL.JAM.Compiler.runtime([call])
    assert {{:call, _, _, {:register, _}, _}} = code

    program =
      Program.lower([
        %Goal.Or{or: [%Goal.Eq{a: :"$Body", b: first}], then: [%Goal.Eq{a: :"$Body", b: second}]},
        call
      ])

    assert answers(program) == [:first, :second]
  end

  test "a static callable preserves partially bound capture aliases" do
    body = [%Goal.Compound{name: :=, args: [:"$Argument", :"$Capture"]}]

    {code, slots} =
      AL.JAM.Compiler.runtime([
        %Goal.Call{head: [:"$Argument"], body: body, args: [:"$Output"]}
      ])

    for value <- [1, 2] do
      store = %{:"$Capture" => [:"$Shared", :"$Shared"], :"$Output" => [value, value]}

      assert {:ok, _, _} =
               AL.JAM.resume({:test, code, 0, slots, [], store, %{}}, AL.Branch.head(), 100)
    end

    store = %{:"$Capture" => [:"$Shared", :"$Shared"], :"$Output" => [1, 2]}

    assert {:failed, _, _} =
             AL.JAM.resume({:test, code, 0, slots, [], store, %{}}, AL.Branch.head(), 100)
  end

  test "runtime-supplied goals and primitive selectors use dynamic source compilation" do
    call = %Goal.Call{head: [:"$Argument"], body: [:"$Goal"], args: [:"$Output"]}
    {code, slots} = AL.JAM.Compiler.runtime([call])
    refute match?({{:call, _, _, {:compiled_callable, _, _, _}, _}}, code)

    for value <- [:first, :second] do
      goal = %Goal.Compound{name: :=, args: [:"$Argument", value]}
      snapshot = {:test, code, 0, slots, [], %{:"$Goal" => goal}, %{}}
      assert {:ok, store, _} = AL.JAM.resume(snapshot, AL.Branch.head(), 100)
      assert AL.Var.subst(:"$Output", store) == value
    end

    selected = %Goal.Call{
      head: [:"$Argument"],
      body: [%Goal.Compound{name: :"$Selector", args: [:"$Argument"]}],
      args: [:value]
    }

    {code, slots} = AL.JAM.Compiler.runtime([selected])
    snapshot = {:test, code, 0, slots, [], %{:"$Selector" => :atom}, %{}}
    assert {:ok, _, _} = AL.JAM.resume(snapshot, AL.Branch.head(), 100)
  end

  test "callable arguments follow bound spines while retaining nested aliases" do
    call = %Goal.Call{head: [:"$Arg", :"$Arg"], body: [], args: :"$Args"}

    program =
      Program.lower([
        %Goal.Eq{a: :"$Args", b: [:"$Output" | :"$Tail"]},
        %Goal.Eq{a: :"$Tail", b: [[1, :"$Shared"]]},
        call,
        %Goal.Eq{a: :"$Shared", b: 2}
      ])

    assert IR.Inference.operation(IR.lower(call), MapSet.new()).access == [
             :deep,
             :deep,
             :reference
           ]

    assert answers(program) == [[1, 2]]
  end

  test "callable matching completes an open argument tail" do
    call = %Goal.Call{head: [:value], body: [], args: [:value | :"$Output"]}
    assert answers(Program.lower([call])) == [[]]
  end

  test "callable argument spines follow each backtracking alternative" do
    call = %Goal.Call{
      head: [:"$Arg", :"$Result"],
      body: [%Goal.Eq{a: :"$Result", b: :"$Arg"}],
      args: :"$Args"
    }

    program =
      Program.lower([
        %Goal.Or{
          or: [%Goal.Eq{a: :"$Args", b: [:first, :"$Output"]}],
          then: [%Goal.Eq{a: :"$Args", b: [:second, :"$Output"]}]
        },
        call
      ])

    assert answers(program) == [:first, :second]
  end
end
