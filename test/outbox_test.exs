defmodule ALOutboxTest do
  use ExUnit.Case, async: false
  use AL

  def block(_receiver, observer) do
    send(observer, {:outbox_call_started, self()})

    receive do
      :release -> :ok
    end
  end

  test "stopping an outbox stops its running calls before dropping the branch" do
    branch = AL.TestBranch.fork()

    try do
      {:ok, _method} =
        AL.Native.register(:number, :outbox_block, __MODULE__, :block, 2, branch: branch)

      observer = self()
      branch_id = branch.id

      {:atomic, _} =
        run branch: branch_id do
          ~AL"""
          send_async 1 outbox_block [^observer, _].
          """
        end

      assert_receive {:outbox_call_started, task}, 2_000
      ref = Process.monitor(task)

      assert :ok = AL.Outbox.stop(branch)
      assert_receive {:DOWN, ^ref, :process, ^task, :killed}, 2_000
    after
      AL.Branch.discard(branch)
    end
  end
end
