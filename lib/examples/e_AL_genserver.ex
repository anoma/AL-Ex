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

    def start_link(object_id, observer) do
      GenServer.start_link(__MODULE__, {object_id, observer})
    end

    @impl true
    def init({object_id, observer}) do
      pid = self()

      run branch: Examples.Support.branch() do
        new(:process, %{name: ^object_id, pid: ^pid}, _)

        defmethod(^object_id, :increment, [self, amount]) do
          get(self, :pid, p)
          message = %{event: :increment, amount: amount}
          send_elixir(p, message)
        end
      end

      {:ok, %{object_id: object_id, observer: observer, count: 0}}
    end

    @impl true
    def handle_info(%{event: :increment, amount: amount}, state) do
      state = %{state | count: state.count + amount}
      send(state.observer, {:count_changed, self(), state.count})
      {:noreply, state}
    end

    @impl true
    def terminate(_reason, state) do
      object_id = state.object_id

      run branch: Examples.Support.branch() do
        vm_retract_class(^object_id, c)
        vm_retract_super(^object_id, s)
      end
    end
  end

  example genserver_registers_as_al_object() do
    {:ok, pid} = CounterService.start_link(:my_counter, self())

    {:atomic, results} =
      :mnesia.transaction(fn ->
        AL.Object.scan_class(:my_counter, :"$class", %AL.Branch{id: :examples})
      end)

    assert Enum.any?(results, fn {:class, _, _seq, c} -> c == :process end)

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        send_async(:my_counter, :increment, [5])
      end

    assert_receive {:count_changed, ^pid, 5}, 1000

    GenServer.stop(pid)

    {:atomic, after_stop} =
      :mnesia.transaction(fn ->
        AL.Object.scan_class(:my_counter, :"$class", %AL.Branch{id: :examples})
      end)

    assert after_stop == []

    :ok
  end
end
