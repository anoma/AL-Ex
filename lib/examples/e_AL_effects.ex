defmodule Examples.ALEffects.Provider do
  use AL.Edge, provider: :example_effect

  def observe(pid), do: :persistent_term.put({__MODULE__, :observer}, pid)

  def execute(:echo, [value], _context), do: {:ok, value}
  def execute(:transaction_context, [], _context), do: {:ok, :mnesia.is_transaction()}
  def execute(:branch, [], %{branch: branch}), do: {:ok, branch.id}
  def execute(:raise, [], _context), do: raise("provider failed")

  def execute(:notify, [], _context) do
    send(observer(), :effect_ran)
    {:ok, :notified}
  end

  def execute(:wait, [value], context) do
    send(observer(), {:effect_pending, context, value})
    :pending
  end

  defp observer(), do: :persistent_term.get({__MODULE__, :observer})
end

defmodule Examples.ALEffects do
  @moduledoc "I exercise compact post-commit edge effects."

  use ExExample
  use AL
  import ExUnit.Assertions

  defp register_receiver(receiver, subscriber, pid) do
    :ok = AL.Edge.register(Examples.ALEffects.Provider)
    :ok = Examples.ALEffects.Provider.observe(pid)

    {:atomic, _} =
      run branch: :examples do
        new(:process, %{name: ^subscriber, pid: ^pid}, _)
        vm_set_class(^receiver, :object)

        defmethod(^receiver, :effect_result, [self, label, effect_id, outcome]) do
          get(^subscriber, :pid, p)
          functor(message, :effect_result, [label, effect_id, outcome])
          send_elixir(p, message)
        end
      end

    :ok
  end

  example file_read_effect_saves_contents_on_an_object() do
    path = temporary_path()
    pid = self()
    File.write!(path, "alpha\nbeta\n")

    try do
      {:atomic, _} =
        run branch: :examples do
          new(:process, %{name: :file_effect_subscriber, pid: ^pid}, _)
          vm_set_class(:file_effect_receiver, :object)
          set_slot(:file_effect_receiver, :contents, :pending)

          defmethod(
            :file_effect_receiver,
            :file_read,
            [self, effect_id, {:ok, contents}]
          ) do
            set_slot(self, :contents, contents)
            get(:file_effect_subscriber, :pid, p)
            functor(message, :file_read, [effect_id, contents])
            send_elixir(p, message)
          end

          emit_effect(:file, :read, [^path], {:file_effect_receiver, :file_read, []})
        end

      assert_receive {:file_read, {:examples, effect_time}, "alpha\nbeta\n"}, 1000
      assert is_integer(effect_time)

      {:atomic, {result, _state}} =
        run branch: :examples do
          get(:file_effect_receiver, :contents, contents)
        end

      assert result[:"$contents"] == "alpha\nbeta\n"
    after
      File.rm(path)
    end
  end

  example effect_runs_after_commit_and_replies_in_a_new_transaction() do
    register_receiver(:effect_receiver, :effect_subscriber, self())

    {:atomic, {_bindings, state}} =
      run branch: :examples do
        emit_effect(
          :example_effect,
          :transaction_context,
          [],
          {:effect_receiver, :effect_result, [:context]}
        )
      end

    assert_receive {:effect_result, :context, {:examples, effect_time}, {:ok, false}}, 1000

    {:atomic, commands} =
      :mnesia.transaction(fn ->
        AL.Command.commands_for_transaction(state.tx_id, %AL.Branch{id: :examples})
      end)

    assert Enum.any?(commands, fn
             {:command, ^effect_time, _tx_id,
              {:effect,
               {:example_effect, :transaction_context, [],
                {:effect_receiver, :effect_result, [:context]}}}} ->
               true

             _ ->
               false
           end)
  end

  example aborted_transaction_does_not_run_effect() do
    :ok = AL.Edge.register(Examples.ALEffects.Provider)
    :ok = Examples.ALEffects.Provider.observe(self())

    {:aborted, _} =
      run branch: :examples do
        emit_effect(:example_effect, :notify, [], :none)
        fail()
      end

    refute_receive :effect_ran, 100
  end

  example al_method_can_emit_effect() do
    register_receiver(:method_effect_receiver, :method_effect_subscriber, self())

    {:atomic, _} =
      run branch: :examples do
        vm_set_class(:effect_emitter, :object)

        defmethod(:effect_emitter, :emit, [self, reply_to]) do
          emit_effect(
            :example_effect,
            :echo,
            [:from_method],
            {reply_to, :effect_result, [:method]}
          )
        end

        send(:effect_emitter, :emit, [:method_effect_receiver])
      end

    assert_receive {:effect_result, :method, {:examples, _effect_time}, {:ok, :from_method}},
                   1000
  end

  example effect_request_must_be_ground_and_durable() do
    {:aborted, {%ArgumentError{message: ground_message}, _stacktrace}} =
      run branch: :examples do
        emit_effect(:example_effect, :echo, [unbound], :none)
      end

    assert ground_message == "effect request must be ground"
    branch = %AL.Branch{id: :examples}

    {:aborted, {%ArgumentError{message: durable_message}, _stacktrace}} =
      :mnesia.transaction(fn ->
        AL.Edge.emit(0, :example_effect, :echo, [self()], :none, branch)
      end)

    assert durable_message == "effect request contains a live host value"
  end

  example pending_effect_can_complete_later() do
    register_receiver(:pending_effect_receiver, :pending_effect_subscriber, self())

    {:atomic, _} =
      run branch: :examples do
        emit_effect(
          :example_effect,
          :wait,
          [:later],
          {:pending_effect_receiver, :effect_result, [:pending]}
        )
      end

    assert_receive {:effect_pending, context, :later}, 1000
    refute_receive {:effect_result, :pending, _, _}, 100
    assert :ok = AL.Edge.complete(context, {:ok, :later})

    assert_receive {:effect_result, :pending, {:examples, _effect_time}, {:ok, :later}}, 1000
  end

  example provider_exception_returns_a_tagged_error() do
    register_receiver(:raising_effect_receiver, :raising_effect_subscriber, self())

    {:atomic, _} =
      run branch: :examples do
        emit_effect(
          :example_effect,
          :raise,
          [],
          {:raising_effect_receiver, :effect_result, [:raised]}
        )
      end

    assert_receive {:effect_result, :raised, {:examples, _effect_time},
                    {:error, {:effect_exception, "provider failed"}}},
                   1000
  end

  example multiple_effects_in_one_transaction_all_run_with_distinct_ids() do
    register_receiver(:multiple_effect_receiver, :multiple_effect_subscriber, self())

    {:atomic, _} =
      run branch: :examples do
        emit_effect(
          :example_effect,
          :echo,
          [:first],
          {:multiple_effect_receiver, :effect_result, [:first]}
        )

        emit_effect(
          :example_effect,
          :echo,
          [:second],
          {:multiple_effect_receiver, :effect_result, [:second]}
        )
      end

    assert_receive {:effect_result, :first, first_id, {:ok, :first}}, 1000
    assert_receive {:effect_result, :second, second_id, {:ok, :second}}, 1000
    assert first_id != second_id
  end

  example hydrating_the_command_log_does_not_repeat_effects() do
    :ok = AL.Edge.register(Examples.ALEffects.Provider)
    :ok = Examples.ALEffects.Provider.observe(self())
    branch = %AL.Branch{id: :examples}
    :ok = AL.Scheduler.stop(branch)

    try do
      {:atomic, {_bindings, state}} =
        run branch: :examples do
          emit_effect(:example_effect, :notify, [], :none)
        end

      {:atomic, commands} =
        :mnesia.transaction(fn -> AL.Command.commands_for_transaction(state.tx_id, branch) end)

      effect_time =
        Enum.find_value(commands, fn
          {:command, time, _tx_id, {:effect, _request}} -> time
          _command -> nil
        end)

      assert is_integer(effect_time)
      assert {:atomic, _result} = AL.Object.hydrate_since(effect_time, branch)
      refute_receive :effect_ran, 100
      :ok = AL.Scheduler.start(branch)
      refute_receive :effect_ran, 100
    after
      AL.Scheduler.start(branch)
    end
  end

  example fork_does_not_replay_parent_effects_and_runs_new_effects() do
    :ok = AL.Edge.register(Examples.ALEffects.Provider)
    :ok = Examples.ALEffects.Provider.observe(self())
    parent = %AL.Branch{id: :examples}
    pid = self()

    {:atomic, _} =
      run branch: :examples do
        new(:process, %{name: :fork_effect_subscriber, pid: ^pid}, _)
        vm_set_class(:fork_effect_receiver, :object)

        defmethod(
          :fork_effect_receiver,
          :record_effect,
          [self, marker, effect_id, outcome]
        ) do
          vm_set_class(marker, :object)
          get(:fork_effect_subscriber, :pid, p)
          functor(message, :fork_effect_result, [effect_id, outcome])
          send_elixir(p, message)
        end
      end

    :ok = AL.Scheduler.stop(parent)

    try do
      {:atomic, _} =
        run branch: :examples do
          emit_effect(:example_effect, :notify, [], :none)
        end

      child = AL.Branch.fork(:tip, parent)

      try do
        refute_receive :effect_ran, 100

        {:atomic, _} =
          run branch: child.id do
            emit_effect(
              :example_effect,
              :branch,
              [],
              {:fork_effect_receiver, :record_effect, [:fork_effect_callback_marker]}
            )
          end

        assert_receive {:fork_effect_result, {child_id, _effect_time}, {:ok, child_id}}, 1000
        assert child_id == child.id

        child_result =
          run branch: child.id do
            class(:fork_effect_callback_marker, :object)
          end

        parent_result =
          run branch: :examples do
            class(:fork_effect_callback_marker, :object)
          end

        assert {:atomic, _} = child_result
        assert {:aborted, _} = parent_result
      after
        AL.Branch.discard(child)
      end
    after
      AL.Scheduler.start(parent)
    end
  end

  defp temporary_path do
    Path.join(System.tmp_dir!(), "al_file_effect_#{System.unique_integer([:positive])}.txt")
  end
end
