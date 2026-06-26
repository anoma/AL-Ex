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
        set_class(^sym, :object)
      end

    past = AL.Branch.fork(before - 1)
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
        set_slots(:widget, %{x: 3})
        get_slot(:widget, :x, x)
      end

    assert Map.get(bindings, :"$x") == 3

    # main never saw :widget — the write stayed in the fork's log
    {:aborted, _} =
      run do
        get_slot(:widget, :x, x)
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
        set_class(:on_branch, :object)
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
        set_class(:on_parent, :object)
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
        set_class(:later_on_parent, :object)
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
        set_class(:on_head, :object)
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

    # a worker object that lives only on the fork, built from bootstrap primitives
    {:atomic, _} =
      run branch: branch.id do
        set_class(:fork_worker, :object)

        defmethod(:fork_worker, :handle, [self, object]) do
          set_slots(object, %{processed: true})
        end
      end

    # an async send written into the fork is handled against the fork
    {:atomic, _} =
      run branch: branch.id do
        send_async(:fork_worker, :handle, [:fork_obj])
      end

    Process.sleep(50)

    {:atomic, {fork_bindings, _}} =
      run branch: branch.id do
        get_slot(:fork_obj, :processed, v)
      end

    assert Map.get(fork_bindings, :"$v") == true

    # main never saw the worker or the effect
    {:aborted, _} =
      run do
        get_slot(:fork_obj, :processed, v)
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
        set_class(:survivor, :object)
      end

    {:atomic, _} =
      run branch: child.id do
        class(:survivor, :object)
      end

    AL.Branch.discard(child)
    :ok
  end
end
