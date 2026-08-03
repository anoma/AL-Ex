defmodule Examples.ALGenserver do
  @moduledoc """
  I demonstrate the pattern of registering an Elixir GenServer as an AL object.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  defmodule CounterService do
    use GenServer
    use AL

    def start_link(object_id) do
      GenServer.start_link(__MODULE__, object_id)
    end

    @impl true
    def init(object_id) do
      pid = self()

      run branch: :examples do
        new(:process, %{name: ^object_id, pid: ^pid}, _)

        defmethod(^object_id, :increment, [self, amount]) do
          get_slot(self, :pid, p)
          vm_functor(message, :increment, [amount])
          send_elixir(p, message)
        end
      end

      {:ok, %{object_id: object_id, count: 0}}
    end

    @impl true
    def handle_info({:increment, amount}, state) do
      {:noreply, %{state | count: state.count + amount}}
    end

    @impl true
    def handle_info({:get_count, reply_to}, state) do
      send(reply_to, {:count, state.count})
      {:noreply, state}
    end

    @impl true
    def terminate(_reason, state) do
      object_id = state.object_id

      run branch: :examples do
        vm_retract_class(^object_id, c)
        vm_retract_super(^object_id, s)
      end
    end

    def count(pid) do
      send(pid, {:get_count, self()})

      receive do
        {:count, n} -> n
      after
        1000 -> :timeout
      end
    end
  end

  # `send_async`'s scheduler pickup has no ordering guarantee against this
  # test's own next `count/1` call — `count/1` is already a real synchronous
  # round-trip to `CounterService` (send + receive), so polling it is enough
  # to wait for the actual result instead of guessing a `Process.sleep`
  # duration; no new notification channel needed on top of what's already there.
  defp wait_for_count(pid, expected, deadline \\ System.monotonic_time(:millisecond) + 1000)

  defp wait_for_count(pid, expected, deadline) do
    case CounterService.count(pid) do
      ^expected ->
        expected

      other ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out waiting for count to reach #{expected}, last saw #{inspect(other)}")
        else
          Process.sleep(5)
          wait_for_count(pid, expected, deadline)
        end
    end
  end

  example genserver_registers_as_al_object() do
    {:ok, pid} = CounterService.start_link(:my_counter)

    {:atomic, results} =
      :mnesia.transaction(fn ->
        AL.Object.scan_class(:my_counter, :"$class", %AL.Branch{id: :examples})
      end)

    assert Enum.any?(results, fn {:class, _, _seq, c} -> c == :process end)

    {:atomic, _} =
      run branch: :examples do
        send_async(:my_counter, :increment, [5])
      end

    assert wait_for_count(pid, 5) == 5

    # `GenServer.stop/1` is synchronous — it only returns once the process has
    # actually terminated, which (for a normal stop) means `terminate/2` (and
    # its retract transaction) has already run. No sleep needed after it.
    GenServer.stop(pid)

    {:atomic, after_stop} =
      :mnesia.transaction(fn ->
        AL.Object.scan_class(:my_counter, :"$class", %AL.Branch{id: :examples})
      end)

    assert after_stop == []

    :ok
  end
end
