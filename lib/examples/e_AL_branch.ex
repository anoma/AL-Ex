defmodule Examples.ALBranch do
  @moduledoc """
  I provide branch (Git-like command-log management) examples for AL: a branch is a
  divergent command log materialised into its own store.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example read_from_fork() do
    # time just before we introduce :tt_thing
    before = AL.Command.system_time()

    sym = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower) |> String.to_atom()

    {:atomic, _} =
      run do
        vm_set_class(^sym, :object)
      end

    past = AL.Branch.fork(before)
    tip = AL.Branch.fork()

    # the tip fork sees :tt_thing; the past fork does not
    {:atomic, _} =
      run branch: tip.id do
        class(^sym, :object)
      end

    {:aborted, _} =
      run branch: past.id do
        class(^sym, :object)
      end

    # both forks still carry the bootstrap
    {:atomic, _} =
      run branch: past.id do
        class(:object, :class)
      end

    AL.Branch.discard(past)
    AL.Branch.discard(tip)
    :ok
  end

  example write_to_fork() do
    tip = AL.Branch.fork()

    # write only into the fork, then read it back from the fork's projection
    {:atomic, {bindings, _}} =
      run branch: tip.id do
        vm_set_slot(:widget, :x, 3)
        vm_get_slot(:widget, :x, x)
      end

    assert Map.get(bindings, :"$x") == 3

    # main never saw :widget — the write stayed in the fork's log
    {:aborted, _} =
      run do
        vm_get_slot(:widget, :x, x)
      end

    AL.Branch.discard(tip)
    :ok
  end

  example checkout_switches_head() do
    branch = AL.Branch.fork()
    AL.Branch.checkout(branch)

    # with the branch checked out, plain `run` acts against it
    {:atomic, _} =
      run do
        vm_set_class(:on_branch, :object)
      end

    {:atomic, _} =
      run do
        class(:on_branch, :object)
      end

    # back on main, the branch's write is invisible
    AL.Branch.checkout(AL.Branch.main())

    {:aborted, _} =
      run do
        class(:on_branch, :object)
      end

    AL.Branch.discard(branch)
    :ok
  end

  example fork_from_another_branch() do
    parent = AL.Branch.fork()

    # a write that lives only on the parent fork
    {:atomic, _} =
      run branch: parent.id do
        vm_set_class(:on_parent, :object)
      end

    # forking the parent (not main) carries the parent's divergent history
    child = AL.Branch.fork(:tip, parent)

    {:atomic, _} =
      run branch: child.id do
        class(:on_parent, :object)
      end

    # writes to the parent after the child forked don't reach the child
    {:atomic, _} =
      run branch: parent.id do
        vm_set_class(:later_on_parent, :object)
      end

    {:aborted, _} =
      run branch: child.id do
        class(:later_on_parent, :object)
      end

    # main never saw any of it
    {:aborted, _} =
      run do
        class(:on_parent, :object)
      end

    AL.Branch.discard(child)
    AL.Branch.discard(parent)
    :ok
  end

  example fork_defaults_to_head() do
    branch = AL.Branch.fork()
    AL.Branch.checkout(branch)

    {:atomic, _} =
      run do
        vm_set_class(:on_head, :object)
      end

    # fork() with no args forks the checked-out branch, not main
    child = AL.Branch.fork()

    {:atomic, _} =
      run branch: child.id do
        class(:on_head, :object)
      end

    # main, which was never checked out, has no such object to fork
    AL.Branch.checkout(AL.Branch.main())
    fresh = AL.Branch.fork()

    {:aborted, _} =
      run branch: fresh.id do
        class(:on_head, :object)
      end

    AL.Branch.discard(fresh)
    AL.Branch.discard(child)
    AL.Branch.discard(branch)
    :ok
  end

  example async_send_stays_on_fork() do
    branch = AL.Branch.fork()
    pid = self()

    # a worker object that lives only on the fork, built from bootstrap
    # primitives — its handler notifies a registered `:process` once
    # done, the same synchronization `Examples.ALConstraints` uses: a blocking
    # `receive` instead of a guessed `Process.sleep`, since `send_async`'s
    # scheduler pickup has no ordering guarantee against this test's own next line.
    {:atomic, _} =
      run branch: branch.id do
        new(:process, %{name: :fork_worker_subscriber, pid: ^pid}, _)

        vm_set_class(:fork_worker, :object)

        defmethod(:fork_worker, :handle, [self, object]) do
          vm_set_slot(object, :processed, true)
          get_slot(:fork_worker_subscriber, :pid, p)
          vm_functor(message, :handled, [object])
          send_elixir(p, message)
        end
      end

    # an async send written into the fork is handled against the fork
    {:atomic, _} =
      run branch: branch.id do
        send_async(:fork_worker, :handle, [:fork_obj])
      end

    receive do
      {:handled, :fork_obj} -> :ok
    after
      1000 -> flunk("timed out waiting for :fork_obj to be handled")
    end

    {:atomic, {fork_bindings, _}} =
      run branch: branch.id do
        vm_get_slot(:fork_obj, :processed, v)
      end

    assert Map.get(fork_bindings, :"$v") == true

    # main never saw the worker or the effect
    {:aborted, _} =
      run do
        vm_get_slot(:fork_obj, :processed, v)
      end

    AL.Branch.discard(branch)
    :ok
  end

  example discard_reparents_forks() do
    parent = AL.Branch.fork()
    child = AL.Branch.fork(:tip, parent)

    assert {:branch, parent, child} in AL.Branch.branch_graph()

    AL.Branch.discard(parent)

    # the child is reparented onto the parent's parent, not orphaned or dropped
    assert {:branch, AL.Branch.main(), child} in AL.Branch.branch_graph()
    refute parent in AL.Branch.list()
    assert child in AL.Branch.list()

    # the child's log is independent, so it still works after its parent is gone
    {:atomic, _} =
      run branch: child.id do
        vm_set_class(:survivor, :object)
      end

    {:atomic, _} =
      run branch: child.id do
        class(:survivor, :object)
      end

    AL.Branch.discard(child)
    :ok
  end

  # A nil branch is scoped: forked for the fun, discarded after.
  example on_nil_forks_and_discards() do
    seen =
      AL.Branch.on(nil, fn branch ->
        assert Enum.any?(AL.Branch.list(), &(&1.id == branch.id))
        branch
      end)

    refute Enum.any?(AL.Branch.list(), &(&1.id == seen.id))
    seen
  end

  example on_id_keeps_the_branch() do
    branch = AL.Branch.fork()
    result = AL.Branch.on(branch.id, fn b -> b.id end)

    assert result == branch.id
    assert Enum.any?(AL.Branch.list(), &(&1.id == branch.id))
    AL.Branch.discard(branch)
    branch
  end

  example joining_process_does_not_rehydrate_the_projection() do
    branch = AL.Branch.main()
    before = projection_rows(branch)

    assert before != []

    as_joiner(fn -> AL.Branch.setup() end)

    assert projection_rows(branch) == before

    {:atomic, _} =
      run do
        class(:object, :class)
      end

    :ok
  end

  example many_slot_writes_in_one_transaction_stay_linear() do
    branch = AL.Branch.fork()

    {microseconds, {:atomic, _}} =
      :timer.tc(fn ->
        :mnesia.transaction(fn ->
          for i <- 1..2000 do
            AL.Object.set_slot(:"perf_#{rem(i, 50)}", :"k#{i}", i, :aos, i, branch)
          end
        end)
      end)

    AL.Branch.discard(branch)

    assert microseconds < 1_000_000,
           "2000 slot writes in one transaction took #{div(microseconds, 1000)}ms"
  end

  defp projection_rows(branch) do
    {:atomic, rows} =
      :mnesia.transaction(fn ->
        :mnesia.match_object(
          AL.Object.table(:soa, branch),
          {:soa, :_, :_, :_, :_, :_, :_},
          :read
        )
      end)

    Enum.sort(rows)
  end

  defp as_joiner(fun) do
    key = {AL.Command, :owner_node}
    previous = :persistent_term.get(key, :absent)
    :persistent_term.put(key, :"al_joiner@127.0.0.1")

    try do
      fun.()
    after
      case previous do
        :absent -> :persistent_term.erase(key)
        node -> :persistent_term.put(key, node)
      end
    end
  end
end
