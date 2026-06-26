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
        new(:elixir_process, %{name: ^object_id, pid: ^pid}, _)

        defmethod(^object_id, :increment, [self, amount]) do
          get_slot(self, :pid, p)
          send_elixir(p, {:increment, amount})
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
        retract_class(^object_id, c)
        retract_super(^object_id, s)
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

  example genserver_registers_as_al_object() do
    {:ok, pid} = CounterService.start_link(:my_counter)

    {:atomic, results} =
      :mnesia.transaction(fn -> AL.Object.scan_class(:my_counter, :"$class", :examples) end)

    assert Enum.any?(results, fn {:class, _, c} -> c == :elixir_process end)

    {:atomic, _} =
      run branch: :examples do
        send_async(:my_counter, :increment, [5])
      end

    Process.sleep(50)

    assert CounterService.count(pid) == 5

    GenServer.stop(pid)
    Process.sleep(50)

    {:atomic, after_stop} =
      :mnesia.transaction(fn -> AL.Object.scan_class(:my_counter, :"$class", :examples) end)

    assert after_stop == []

    :ok
  end
end
