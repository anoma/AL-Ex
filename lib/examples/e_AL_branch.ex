defmodule Examples.ALBranch do
  @moduledoc """
  I provide branch (Git-like command-log management) examples for AL: a branch is a
  divergent command log materialised into its own store.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example branch_classification_tracks_discard_and_reparenting() do
    parent = AL.Branch.fork(:tip, %AL.Branch{id: Examples.Support.branch()})
    child = AL.Branch.fork(:tip, parent)
    parent_id = parent.id
    child_id = child.id

    try do
      result =
        run(
          ~S"""
          isa HostParentId branch.
          isa HostParentId branch.
          isa HostChildId branch.
          not {isa jam_missing_branch_registration branch}.
          not {isa jam_missing_branch_registration branch}.
          """,
          branch: Examples.Support.branch(),
          bindings: %{"HostChildId" => child_id, "HostParentId" => parent_id}
        )

      assert {:atomic, _} = result
      AL.Branch.discard(parent)

      result =
        run(
          ~S"""
          not {isa HostParentId branch}.
          not {isa HostParentId branch}.
          isa HostChildId branch.
          isa HostChildId branch.
          """,
          branch: Examples.Support.branch(),
          bindings: %{"HostChildId" => child_id, "HostParentId" => parent_id}
        )

      assert {:atomic, _} = result
    after
      AL.Branch.discard(child)
      if parent in AL.Branch.list(), do: AL.Branch.discard(parent)
    end
  end

  example read_from_fork() do
    # time just before we introduce :tt_thing
    before = AL.Command.system_time()

    sym = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower) |> String.to_atom()

    {:atomic, _} =
      run(
        ~S"""
        vm_set_class HostSym object.
        """,
        bindings: %{"HostSym" => sym}
      )

    past = AL.Branch.fork(before)
    tip = AL.Branch.fork()

    # the tip fork sees :tt_thing; the past fork does not
    {:atomic, _} =
      run(
        ~S"""
        class HostSym object.
        """,
        branch: tip.id,
        bindings: %{"HostSym" => sym}
      )

    {:aborted, _} =
      run(
        ~S"""
        class HostSym object.
        """,
        branch: past.id,
        bindings: %{"HostSym" => sym}
      )

    # both forks still carry the bootstrap
    {:atomic, _} =
      run(
        ~S"""
        class object class.
        """,
        branch: past.id
      )

    AL.Branch.discard(past)
    AL.Branch.discard(tip)
    :ok
  end

  example branches_are_objects_you_can_query() do
    parent = Examples.Support.isolated_branch()
    child = AL.Branch.fork(:tip, parent)
    at_fork = AL.Command.fork_point(child)
    parent_id = parent.id
    child_id = child.id

    {:atomic, {bindings, _constraints, _state}} =
      run(
        ~S"""
        class HostChildId Class.
        parent HostChildId Parent.
        child HostParentId Child.
        fork_point HostChildId Point.
        current Here.
        findall B Branches {class B branch, label B}.
        """,
        branch: parent.id,
        bindings: %{"HostChildId" => child_id, "HostParentId" => parent_id}
      )

    assert Map.get(bindings, "$Class") == :branch
    assert Map.get(bindings, "$Parent") == parent_id
    assert Map.get(bindings, "$Child") == child_id
    assert Map.get(bindings, "$Point") == at_fork
    assert Map.get(bindings, "$Here") == parent_id
    assert Enum.all?([:main, parent_id, child_id], &(&1 in Map.get(bindings, "$Branches")))

    AL.Branch.discard(child)
    AL.Branch.discard(parent)
    :ok
  end

  example branches_fork_and_discard_through_effects() do
    parent = Examples.Support.isolated_branch()
    parent_id = parent.id
    pid = self()

    report = fn event, goals ->
      {:atomic, _} =
        AL.run(
          """
          #{goals}
          await Effect [Outcome] {
            get branch_effect_observer pid Observer,
            send_elixir Observer \#{event => #{event}, outcome => Outcome}
          }.
          """,
          parent
        )
    end

    try do
      {:atomic, _} =
        run(
          ~S"""
          new process #{name => branch_effect_observer, pid => HostPid} _.
          """,
          branch: parent.id,
          bindings: %{"HostPid" => pid}
        )

      report.("forked", "fork #{parent_id} tip Effect.")
      assert_receive %{event: :forked, outcome: %{status: :ok, value: child_id}}, 2_000
      assert %AL.Branch{id: child_id} in AL.Branch.list()

      {:atomic, {bindings, _constraints, _state}} =
        run(
          ~S"""
          parent HostChildId Parent.
          """,
          branch: parent.id,
          bindings: %{"HostChildId" => child_id}
        )

      assert Map.get(bindings, "$Parent") == parent_id

      report.("discarded", "discard #{child_id} Effect.")
      assert_receive %{event: :discarded, outcome: %{status: :ok, value: ^child_id}}, 2_000
      refute %AL.Branch{id: child_id} in AL.Branch.list()

      report.("main_discarded", "discard main Effect.")
      assert_receive %{event: :main_discarded, outcome: %{status: :error}}, 2_000

      report.("own_reset", "reset #{parent_id} Effect.")
      assert_receive %{event: :own_reset, outcome: %{status: :error}}, 2_000
    after
      AL.Branch.discard(parent)
    end

    :ok
  end

  example reset_and_reset_to_shift_a_fork_along_its_parent() do
    parent = Examples.Support.isolated_branch()
    at_fork = AL.Command.system_time(parent)
    child = AL.Branch.fork(:tip, parent)
    assert AL.Command.fork_point(child) == at_fork

    on_parent = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower) |> String.to_atom()
    on_child = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower) |> String.to_atom()

    {:atomic, _} =
      run(
        ~S"""
        vm_set_class HostOnParent object.
        """,
        branch: parent.id,
        bindings: %{"HostOnParent" => on_parent}
      )

    {:atomic, _} =
      run(
        ~S"""
        vm_set_class HostOnChild object.
        """,
        branch: child.id,
        bindings: %{"HostOnChild" => on_child}
      )

    child = AL.Branch.reset(child)
    assert AL.Command.fork_point(child) == at_fork

    {:aborted, _} =
      run(
        ~S"""
        class HostOnChild object.
        """,
        branch: child.id,
        bindings: %{"HostOnChild" => on_child}
      )

    {:aborted, _} =
      run(
        ~S"""
        class HostOnParent object.
        """,
        branch: child.id,
        bindings: %{"HostOnParent" => on_parent}
      )

    grandchild = AL.Branch.fork(:tip, child)
    child = AL.Branch.reset_to(child, :tip)

    {:atomic, _} =
      run(
        ~S"""
        class HostOnParent object.
        """,
        branch: child.id,
        bindings: %{"HostOnParent" => on_parent}
      )

    assert {:branch, child, grandchild} in AL.Branch.branch_graph()
    assert {:branch, parent, child} in AL.Branch.branch_graph()

    AL.Branch.discard(grandchild)
    AL.Branch.discard(child)
    AL.Branch.discard(parent)
    :ok
  end

  example write_to_fork() do
    tip = AL.Branch.fork()

    # write only into the fork, then read it back from the fork's projection
    {:atomic, {bindings, _constraints, _}} =
      run(
        ~S"""
        vm_set_slot widget x 3.
        slot widget x X.
        """,
        branch: tip.id
      )

    assert Map.get(bindings, "$X") == 3

    # main never saw :widget — the write stayed in the fork's log
    {:aborted, _} =
      run(~S"""
      slot widget x X.
      """)

    AL.Branch.discard(tip)
    :ok
  end

  example checkout_switches_head() do
    branch = AL.Branch.fork()
    AL.Branch.checkout(branch)

    # with the branch checked out, plain `run` acts against it
    {:atomic, _} =
      run(~S"""
      vm_set_class on_branch object.
      """)

    {:atomic, _} =
      run(~S"""
      class on_branch object.
      """)

    # back on main, the branch's write is invisible
    AL.Branch.checkout(AL.Branch.main())

    {:aborted, _} =
      run(~S"""
      class on_branch object.
      """)

    AL.Branch.discard(branch)
    :ok
  end

  example fork_from_another_branch() do
    parent = AL.Branch.fork()

    # a write that lives only on the parent fork
    {:atomic, _} =
      run(
        ~S"""
        vm_set_class on_parent object.
        """,
        branch: parent.id
      )

    # forking the parent (not main) carries the parent's divergent history
    child = AL.Branch.fork(:tip, parent)

    {:atomic, _} =
      run(
        ~S"""
        class on_parent object.
        """,
        branch: child.id
      )

    # writes to the parent after the child forked don't reach the child
    {:atomic, _} =
      run(
        ~S"""
        vm_set_class later_on_parent object.
        """,
        branch: parent.id
      )

    {:aborted, _} =
      run(
        ~S"""
        class later_on_parent object.
        """,
        branch: child.id
      )

    # main never saw any of it
    {:aborted, _} =
      run(~S"""
      class on_parent object.
      """)

    AL.Branch.discard(child)
    AL.Branch.discard(parent)
    :ok
  end

  example fork_defaults_to_head() do
    branch = AL.Branch.fork()
    AL.Branch.checkout(branch)

    {:atomic, _} =
      run(~S"""
      vm_set_class on_head object.
      """)

    # fork() with no args forks the checked-out branch, not main
    child = AL.Branch.fork()

    {:atomic, _} =
      run(
        ~S"""
        class on_head object.
        """,
        branch: child.id
      )

    # main, which was never checked out, has no such object to fork
    AL.Branch.checkout(AL.Branch.main())
    fresh = AL.Branch.fork()

    {:aborted, _} =
      run(
        ~S"""
        class on_head object.
        """,
        branch: fresh.id
      )

    AL.Branch.discard(fresh)
    AL.Branch.discard(child)
    AL.Branch.discard(branch)
    :ok
  end

  example async_send_stays_on_fork() do
    branch = AL.Branch.fork()
    pid = self()

    {:atomic, _} =
      run(
        ~S"""
        new process #{name => fork_worker_subscriber, pid => HostPid} _.
        vm_set_class fork_worker object.

        fork_worker >> handle
        | Self Object |
        vm_set_slot Object processed true,
        get fork_worker_subscriber pid P,
        = Message #{event => handled, object => Object},
        send_elixir P Message.
        """,
        branch: branch.id,
        bindings: %{"HostPid" => pid}
      )

    {:atomic, _} =
      run(
        ~S"""
        send_async fork_worker handle [fork_obj].
        """,
        branch: branch.id
      )

    receive do
      %{event: :handled, object: :fork_obj} -> :ok
    after
      1000 -> flunk("timed out waiting for :fork_obj to be handled")
    end

    {:atomic, {fork_bindings, _constraints, _}} =
      run(
        ~S"""
        slot fork_obj processed V.
        """,
        branch: branch.id
      )

    assert Map.get(fork_bindings, "$V") == true

    {:aborted, _} =
      run(~S"""
      slot fork_obj processed V.
      """)

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
      run(
        ~S"""
        vm_set_class survivor object.
        """,
        branch: child.id
      )

    {:atomic, _} =
      run(
        ~S"""
        class survivor object.
        """,
        branch: child.id
      )

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
      run(~S"""
      class object class.
      """)

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

  example the_projection_is_a_pure_function_of_the_command_log() do
    branch = AL.Branch.fork()

    for source <- rebuild_workload() do
      assert {:atomic, _} = AL.run(source, branch)
    end

    soa_before = projection_rows(branch)
    aos_before = slot_rows(branch)

    assert Enum.any?(aos_before, fn {:aos, _version, _object, _from, to, _map} -> to != :open end)
    assert Enum.any?(soa_before, fn {:soa, _o, _k, _s, _f, to, _v} -> to != :open end)

    :ok = AL.Object.drop_tables(branch)
    :ok = AL.Object.create_tables(branch)
    assert {:atomic, _} = AL.Object.hydrate_since(0, branch)

    assert projection_rows(branch) == soa_before
    assert slot_rows(branch) == aos_before

    AL.Branch.discard(branch)
    length(soa_before)
  end

  defp rebuild_workload do
    [
      """
      @gadget \#{super => object, ivars => [\#{name => size}, \#{name => name}]}.

      gadget >> describe
      | Self Size |
        get Self size Size.
      """,
      """
      new gadget \#{name => a, size => 1} G.
      set_slot G size 2.
      set_slot G size 3.
      set_slots G \#{name => b, size => 4}.
      """,
      """
      gadget >> describe
      | Self Size |
        get Self size Size,
        = Size Size.
      """,
      """
      vm_set_class temp_thing object.
      vm_set_super temp_thing gadget.
      vm_retract_super temp_thing gadget.
      vm_retract_class temp_thing object.
      """,
      """
      vm_set_slot temp_thing k 1.
      vm_set_slot temp_thing k 2.
      vm_retract_slot temp_thing k.
      """
    ]
  end

  defp slot_rows(branch) do
    {:atomic, rows} =
      :mnesia.transaction(fn ->
        :mnesia.match_object(
          AL.Object.table(:aos, branch),
          {:aos, :_, :_, :_, :_, :_},
          :read
        )
      end)

    Enum.sort(rows)
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
