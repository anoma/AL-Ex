defmodule AL.TCPBranchCleanupTest do
  use ExUnit.Case, async: false

  test "discard closes TCP connections before removing branch tables" do
    branch = AL.Branch.fork()
    on_exit(fn -> if branch in AL.Branch.list(), do: AL.Branch.discard(branch) end)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_address, port}} = :inet.sockname(listener)
    tcp_server = Process.whereis(AL.Edge.TCP)

    assert {:ok, :connected} =
             AL.Edge.TCP.execute(:connect, [:branch_socket, "127.0.0.1", port], %{
               branch: branch
             })

    assert {:ok, branch_port} =
             AL.Edge.TCP.execute(:listen, [:branch_listener, "127.0.0.1", 0], %{
               branch: branch
             })

    {:ok, accepted} = :gen_tcp.accept(listener, 1_000)
    on_exit(fn -> :gen_tcp.close(accepted) end)

    :ok = AL.Branch.discard(branch)

    assert {:error, :closed} = :gen_tcp.recv(accepted, 0, 1_000)

    assert {:ok, rebound} =
             :gen_tcp.listen(branch_port, [
               :binary,
               active: false,
               reuseaddr: true,
               ip: {127, 0, 0, 1}
             ])

    :ok = :gen_tcp.close(rebound)
    assert Process.whereis(AL.Edge.TCP) == tcp_server
  end
end
