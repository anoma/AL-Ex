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

    def start_link(object_id, observer, branch) do
      GenServer.start_link(__MODULE__, {object_id, observer, branch})
    end

    @impl true
    def init({object_id, observer, branch}) do
      pid = self()

      run(
        ~S"""
        new process #{name => HostObjectId, pid => HostPid} _.

        HostObjectId >> increment
        | Self Amount |
        get Self pid P,
        = Message #{amount => Amount, event => increment},
        send_elixir P Message.
        """,
        branch: branch,
        bindings: %{"HostObjectId" => object_id, "HostPid" => pid}
      )

      {:ok, %{object_id: object_id, observer: observer, branch: branch, count: 0}}
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

      run(
        ~S"""
        vm_retract_class HostObjectId C.
        vm_retract_super HostObjectId S.
        """,
        branch: state.branch,
        bindings: %{"HostObjectId" => object_id}
      )
    end
  end

  example genserver_registers_as_al_object() do
    {:ok, pid} = CounterService.start_link(:my_counter, self(), Examples.Support.branch())

    {:atomic, results} =
      :mnesia.transaction(fn ->
        AL.Object.scan_class(:my_counter, {:"$var", "class"}, %AL.Branch{
          id: Examples.Support.branch()
        })
      end)

    assert Enum.any?(results, fn {:class, _, _seq, c} -> c == :process end)

    {:atomic, _} =
      run(
        ~S"""
        send_async my_counter increment [5].
        """,
        branch: Examples.Support.branch()
      )

    assert_receive {:count_changed, ^pid, 5}, 1000

    GenServer.stop(pid)

    {:atomic, after_stop} =
      :mnesia.transaction(fn ->
        AL.Object.scan_class(:my_counter, {:"$var", "class"}, %AL.Branch{
          id: Examples.Support.branch()
        })
      end)

    assert after_stop == []

    :ok
  end
end
