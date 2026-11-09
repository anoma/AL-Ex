defmodule AL.RunnerTest.Provider do
  use AL.Edge, provider: :runner_test

  def execute(:hold, [value], context) do
    send(AL.RunnerTest, {:requested, value, context, :mnesia.is_transaction()})
    :pending
  end
end

defmodule AL.RunnerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  setup do
    Process.register(self(), __MODULE__)
    AL.Edge.register(AL.RunnerTest.Provider)
    branch = AL.TestBranch.fork()

    on_exit(fn ->
      AL.Branch.discard(branch)
      AL.Edge.unregister(:runner_test)
    end)

    %{branch: branch}
  end

  test "evaluation commits requests without dispatching them", %{branch: branch} do
    {:ok, parsed} =
      AL.Syntax.parse(~S"""
      new effect #{provider => runner_test, operation => hold, arguments => [one]} Effect,
      await Effect.
      """)

    assert {:atomic, {%{"$Effect" => effect}, _, state}} =
             receipt = AL.eval(parsed.program, nil, branch)

    assert state.post_commit_work.waits == [effect]
    refute_receive {:requested, _, _, _}, 30

    caller = Task.async(fn -> AL.post_commit(receipt) end)
    assert_receive {:requested, :one, context, false}, 2_000
    assert Task.yield(caller, 0) == nil
    assert :ok = AL.Edge.complete(context, {:ok, :done})
    assert %AL{result: {:atomic, _}, children: children} = Task.await(caller)
    assert [%AL{handle: ^effect, result: {:ok, :done}}] = children
  end

  test "a collection preserves committed host work", %{branch: branch} do
    assert %AL{result: {:atomic, {%{"$Results" => [1]}, _, _}}} =
             AL.run(
               "findall X Results {= X 1, send_elixir Observer collected}.",
               branch,
               bindings: %{"Observer" => self()}
             )

    assert_receive :collected, 2_000
  end

  test "a collection schedules the futures it creates", %{branch: branch} do
    assert %AL{result: {:atomic, {%{"$Futures" => [future]}, _, _}}} =
             AL.run(
               ~S"""
               @collection_worker #{super => object}.
               collection_worker >> perform
               | _Self |
               pass.
               new collection_worker Worker.
               findall Future Futures {send_async Worker perform [] Future}.
               """,
               branch
             )

    assert %AL{handle: ^future, result: {:atomic, _}} =
             AL.await_completion(future, branch: branch)
  end

  test "a future completed in its creating transaction does not run", %{branch: branch} do
    assert %AL{result: {:atomic, {%{"$Future" => future}, _, _}}} =
             AL.run(
               ~S"""
               @cancelled_worker #{super => object}.
               cancelled_worker >> perform
               | _Self |
               new effect #{provider => runner_test, operation => hold, arguments => [unexpected]} _Effect.
               new cancelled_worker Worker.
               send_async Worker perform [] Future,
               failed Future #{status => error, reason => cancelled}.
               """,
               branch
             )

    assert %AL{result: {:atomic, _}} =
             AL.run("get Future status completed.", branch, bindings: %{"Future" => future})

    refute_receive {:requested, :unexpected, _, _}, 100
  end

  test "all effects are dispatched before waiting and outcomes are collected", %{branch: branch} do
    caller =
      Task.async(fn ->
        AL.run(
          ~S"""
          new effect #{provider => runner_test, operation => hold, arguments => [one]} A,
          await A,
          new effect #{provider => runner_test, operation => hold, arguments => [two]} B,
          await B,
          await A.
          """,
          branch
        )
      end)

    assert_receive {:requested, :one, first, false}, 2_000
    assert_receive {:requested, :two, second, false}, 2_000
    assert Task.yield(caller, 0) == nil
    AL.Edge.complete(second, {:ok, 2})
    assert Task.yield(caller, 0) == nil
    AL.Edge.complete(first, {:ok, 1})

    assert %AL{result: {:atomic, {bindings, _, state}}, children: children} =
             Task.await(caller)

    assert Enum.map(children, &{&1.handle, &1.result}) == [
             {bindings["$A"], {:ok, 1}},
             {bindings["$B"], {:ok, 2}}
           ]

    assert length(state.post_commit_work.waits) == 2
  end

  test "printing finishes before the runner returns", %{branch: branch} do
    assert capture_io(fn ->
             assert %AL{result: {:atomic, _}, children: children} =
                      AL.run(~S(format "Hello ~a!~%" ["Jamie"].), branch)

             assert [%AL{kind: :effect, result: {:ok, 13}, children: []}] = children
             IO.write("next prompt")
           end) == "Hello Jamie!\nnext prompt"
  end

  test "multiple runners can wait on an effect dispatched by an earlier run", %{branch: branch} do
    assert %AL{result: {:atomic, {%{"$Effect" => effect}, _, _}}} =
             AL.run(
               ~S(new effect #{provider => runner_test, operation => hold, arguments => [shared]} Effect.),
               branch
             )

    assert_receive {:requested, :shared, context, false}, 2_000

    callers =
      for _ <- 1..2 do
        Task.async(fn ->
          AL.run("await Effect.", branch,
            bindings: %{"Effect" => effect},
            wait_timeout: :infinity
          )
        end)
      end

    assert :ok = AL.Edge.complete(context, {:ok, :shared_result})

    for caller <- callers do
      assert %AL{result: {:atomic, _}, children: children} = Task.await(caller)
      assert [%AL{handle: ^effect, result: {:ok, :shared_result}}] = children
    end

    assert %AL{result: {:ok, :shared_result}} =
             AL.await_completion(effect, branch: branch)

    assert {:ok, :shared_result} = AL.await_effect(effect, branch: branch)
  end

  test "await exposes the transaction that consumes the effect outcome", %{branch: branch} do
    caller =
      Task.async(fn ->
        AL.run(
          ~S"""
          @runner_value #{super => object, ivars => [#{name => value, default => none}]}.
          new runner_value #{name => runner_receiver} Receiver.
          new effect #{provider => runner_test, operation => hold, arguments => [input]} Effect.
          on_completion Effect #{status => ok, value => Value} Future {
            set_slot runner_receiver value Value
          }.
          await Future.
          """,
          branch
        )
      end)

    assert_receive {:requested, :input, context, false}, 2_000
    assert Task.yield(caller, 0) == nil
    AL.Edge.complete(context, {:ok, 42})

    assert %AL{result: {:atomic, {%{"$Future" => future}, _, _}}, children: children} =
             Task.await(caller)

    assert [%AL{handle: ^future, kind: :transaction, result: {:atomic, transaction}}] =
             children

    assert is_atom(transaction)

    assert %AL{result: {:atomic, {%{"$Value" => 42}, _, _}}} =
             AL.run("get runner_receiver value Value.", branch)
  end

  test "send_async exposes a completion without implicitly waiting for child effects", %{
    branch: branch
  } do
    assert %AL{result: {:atomic, {%{"$Future" => future}, _, _}}, children: children} =
             AL.run(
               ~S"""
               @runner_worker #{super => object}.
               runner_worker >> perform
               | _Self |
               new effect #{provider => runner_test, operation => hold, arguments => [child]} _Effect.
               new runner_worker Worker.
               send_async Worker perform [] Future.
               await Future.
               """,
               branch
             )

    assert [%AL{handle: ^future, result: {:atomic, _transaction}, children: []}] =
             children

    assert_receive {:requested, :child, context, false}, 2_000
    AL.Edge.complete(context, {:ok, :done})
  end

  test "transactions retain their run, direct causes, and completed objects", %{
    branch: branch
  } do
    assert %AL{
             handle: root,
             result: {:atomic, {%{"$Future" => future}, _, _}},
             children: [%AL{result: {:atomic, child}}]
           } =
             AL.run(
               ~S"""
               @lineage_worker #{super => object}.
               lineage_worker >> perform
               | _Self |
               pass.
               new lineage_worker Worker.
               send_async Worker perform [] Future.
               await Future.
               """,
               branch
             )

    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               get Root run Root,
               get Root futures [Future],
               get Root waits [Future],
               get Root children [Child],
               get Future requested_by Root,
               get Child run Root,
               get Child caused_by [Root].
               """,
               branch,
               bindings: %{"Root" => root, "Future" => future, "Child" => child}
             )
  end

  test "transaction metadata is recorded atomically and replays as slots", %{branch: branch} do
    assert %AL{handle: transaction, result: {:atomic, _}} = AL.run("pass.", branch)

    {:atomic, {commands, history, current}} =
      :mnesia.transaction(fn ->
        [{:slots, ^transaction, current}] = AL.Object.read_slots(transaction, branch)
        commands = AL.Command.commands_for_transaction(current.tx, branch)
        {commands, AL.Object.scan_slots_history(transaction, branch), current}
      end)

    assert [{:command, time, _, {:set_slots, {^transaction, slots, :aos}}}] =
             Enum.filter(commands, fn {:command, _, _, {operation, _}} ->
               operation == :set_slots
             end)

    assert length(slots) == 10
    assert Map.new(slots) == current
    assert [{:slots, ^transaction, ^time, :open, ^current}] = history

    replayed = AL.Branch.fork(:tip, branch)
    on_exit(fn -> AL.Branch.discard(replayed) end)

    assert {:atomic, [{:slots, ^transaction, ^current}]} =
             :mnesia.transaction(fn -> AL.Object.read_slots(transaction, replayed) end)
  end

  test "a pending continuation is restored from modeled slots after outbox restart", %{
    branch: branch
  } do
    assert %AL{result: {:atomic, {%{"$Future" => future}, _, _}}} =
             AL.run(
               ~S"""
               new effect #{provider => runner_test, operation => hold, arguments => [restart]} Effect,
               on_completion Effect Outcome Future {pass}.
               """,
               branch
             )

    assert_receive {:requested, :restart, context, false}, 2_000
    assert :ok = AL.Outbox.stop(branch)
    assert :ok = AL.Outbox.start(branch)
    assert :ok = AL.Edge.complete(context, {:ok, :done})

    assert %AL{handle: ^future, result: {:atomic, _}} =
             AL.await_completion(future, branch: branch)
  end

  test "only the reserved transaction can complete an effect", %{
    branch: branch
  } do
    assert %AL{result: {:atomic, {%{"$Effect" => effect, "$Future" => future}, _, _}}} =
             AL.run(
               ~S"""
               new effect #{provider => runner_test, operation => hold, arguments => [direct]} Effect,
               on_completion Effect Outcome Future {pass}.
               """,
               branch
             )

    assert_receive {:requested, :direct, context, false}, 2_000

    assert %AL{result: {:atomic, _}} =
             AL.run(
               "get Effect completion_transaction Transaction, get Future wait_transaction Transaction, get Transaction status pending.",
               branch,
               bindings: %{"Effect" => effect, "Future" => future}
             )

    assert %AL{result: {:aborted, _}} =
             AL.run("complete Effect \#{status => ok, value => done}.", branch,
               bindings: %{"Effect" => effect}
             )

    assert %AL{result: {:aborted, _}} =
             AL.run("set_slot Effect status completed.", branch, bindings: %{"Effect" => effect})

    assert %AL{result: {:aborted, _}} =
             AL.run("set_slot Effect completion_transaction other_transaction.", branch,
               bindings: %{"Effect" => effect}
             )

    assert :ok = AL.Edge.complete(context, {:ok, :done})

    assert %AL{result: {:atomic, {%{"$Transaction" => transaction}, _, _}}} =
             AL.run("get Effect completed_by Transaction.", branch,
               bindings: %{"Effect" => effect}
             )

    assert %AL{result: {:atomic, _}} =
             AL.run("get Transaction completed_objects [Effect].", branch,
               bindings: %{"Transaction" => transaction, "Effect" => effect}
             )

    assert %AL{handle: ^future, result: {:atomic, _}} =
             AL.await_completion(future, branch: branch)
  end

  test "an aborted effect completion fails its reserved transaction", %{branch: branch} do
    assert %AL{result: {:atomic, {%{"$Effect" => effect, "$Future" => future}, _, _}}} =
             AL.run(
               ~S"""
               new effect #{provider => runner_test, operation => hold, arguments => [failed_completion]} Effect,
               on_completion Effect Outcome Future {pass}.
               """,
               branch
             )

    assert_receive {:requested, :failed_completion, context, false}, 2_000

    assert {:error, _reason} =
             AL.Edge.complete(context, {:ok, :done}, [{:missing_receiver, :missing, []}])

    assert %AL{result: {:error, {:completion_transaction_failed, _}}} =
             AL.await_completion(effect, branch: branch)

    assert %AL{handle: ^future, result: {:aborted, _}} =
             AL.await_completion(future, branch: branch)
  end

  test "committed and failed transaction objects report their terminal result", %{branch: branch} do
    assert %AL{handle: committed, result: {:atomic, _}} = AL.run("pass.", branch)

    assert %AL{handle: ^committed, kind: :transaction, result: {:atomic, ^committed}} =
             AL.await_completion(committed, branch: branch)

    assert %AL{handle: failed, result: {:aborted, reason}} = AL.run("fail.", branch)

    assert %AL{handle: ^failed, kind: :transaction, result: {:aborted, ^reason}} =
             AL.await_completion(failed, branch: branch)
  end

  test "a failed future reports its failure without undoing the caller transaction", %{
    branch: branch
  } do
    assert %AL{result: {:atomic, {bindings, _, _}}, children: children} =
             AL.run(
               ~S"""
               @runner_failure #{super => object}.
               runner_failure >> perform
               | _Self |
               fail.
               new runner_failure Worker.
               send_async Worker perform [] Future.
               await Future.
               """,
               branch
             )

    assert [%AL{handle: future, result: {:aborted, message}, children: []}] = children
    assert future == bindings["$Future"]
    assert is_binary(message)

    assert %AL{result: {:atomic, _}} =
             AL.run("class Worker runner_failure.",
               branch: branch,
               bindings: %{"Worker" => bindings["$Worker"]}
             )
  end

  test "a future honours its own explicit waits", %{branch: branch} do
    caller =
      Task.async(fn ->
        AL.run(
          ~S"""
          @waiting_worker #{super => object}.
          waiting_worker >> perform
          | _Self |
          new effect #{provider => runner_test, operation => hold, arguments => [dependency]} Effect,
          await Effect.
          new waiting_worker Worker.
          send_async Worker perform [] Future.
          await Future.
          """,
          branch
        )
      end)

    assert_receive {:requested, :dependency, context, false}, 2_000
    assert Task.yield(caller, 0) == nil
    AL.Edge.complete(context, {:ok, :done})
    assert %AL{result: {:atomic, _}, children: [future]} = Task.await(caller)

    assert %AL{result: {:atomic, _}, children: [%AL{result: {:ok, :done}}]} =
             future

    assert AL.await_completion(future.handle, branch: branch) == future
  end

  test "aborted transactions dispatch nothing", %{branch: branch} do
    assert %AL{result: {:aborted, _}} =
             AL.run(
               ~S"""
               new effect #{provider => runner_test, operation => hold, arguments => [aborted]} Effect,
               await Effect,
               fail.
               """,
               branch
             )

    refute_receive {:requested, _, _, _}, 30
  end

  test "a failed effect stays beneath its committed ancestors and survives a later wait", %{
    branch: branch
  } do
    caller =
      Task.async(fn ->
        AL.run(
          ~S"""
          @tree_worker #{super => object, ivars => [#{name => marker}]}.
          tree_worker >> inner
          | _Self |
          new effect #{provider => runner_test, operation => hold, arguments => [nested]} Effect,
          await Effect.
          tree_worker >> outer
          | Self |
          set_slot Self marker committed,
          send_async Self inner [] Inner,
          await Inner.
          new tree_worker Worker.
          send_async Worker outer [] Future.
          await Future.
          """,
          branch
        )
      end)

    assert_receive {:requested, :nested, context, false}, 2_000
    assert :ok = AL.Edge.complete(context, {:error, :unavailable})

    assert %AL{result: {:atomic, {bindings, _, _}}, children: [outer]} =
             Task.await(caller)

    assert %AL{kind: :transaction, result: {:atomic, _}, children: [inner]} = outer
    assert %AL{kind: :transaction, result: {:atomic, _}, children: [effect]} = inner
    assert %AL{kind: :effect, result: {:error, :unavailable}, children: []} = effect
    assert AL.await_completion(outer.handle, branch: branch) == outer

    assert %AL{result: {:atomic, _}} =
             AL.run("get Worker marker committed.", branch,
               bindings: %{"Worker" => bindings["$Worker"]}
             )
  end

  test "timeouts report a committed result and do not cancel the effect", %{branch: branch} do
    assert %AL{result: {:atomic, {bindings, _, _}}, children: [timeout]} =
             AL.run(
               ~S"""
               new effect #{provider => runner_test, operation => hold, arguments => [late]} Effect,
               await Effect.
               """,
               branch,
               wait_timeout: 0
             )

    assert %AL{kind: :completion, result: {:error, {:completion_timeout, _}}} = timeout
    assert_receive {:requested, :late, context, false}, 2_000
    AL.Edge.complete(context, {:ok, :late})

    assert %AL{result: {:ok, :late}} =
             AL.await_completion(bindings["$Effect"], branch: branch)
  end

  test "new await and async handle forms round trip through source and stored goals" do
    source = ~S(on_completion E X Future {print X}, send_async O perform [] Other, await Future.)
    {:ok, parsed} = AL.Syntax.parse(source)
    lowered = Enum.map(parsed.program, &AL.Goal.lower/1)
    assert Enum.map(lowered, &AL.Goal.from_stored(AL.Goal.to_stored(&1))) == lowered
    text = AL.Syntax.Printer.program(lowered)
    assert {:ok, %{program: program}} = AL.Syntax.parse(text)
    assert program == parsed.program
  end
end
