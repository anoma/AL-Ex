defmodule Examples.ALPeer do
  @moduledoc "I connect peers and exchange byte messages."

  use ExExample
  use AL
  import ExUnit.Assertions

  example peers_connect_and_exchange_a_message() do
    pid = self()

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        defclass :observed_peer, super: :peer, redef: true do
          defmethod(:receive, [self, socket, message]) do
            call_next_method(self, socket, message)
            functor(event, :peer_message, [self, socket, message])
            send_elixir(^pid, event)
          end
        end

        defworkflow :peer_chat, [] do
          transaction do
            new(:peer, %{peer_name: "Alice"}, alice)
            new(:observed_peer, %{peer_name: "Bob"}, bob)
          end

          transaction do
            connect(alice, bob, socket, connection)
          end

          transaction do
            get(connection, :outcome, {:ok, :connected})
            send_message(alice, socket, "hello", sent)
          end

          transaction do
            get(sent, :outcome, {:ok, _bytes})
          end
        end
      end

    assert {:ok, _workflow} =
             AL.workflow(:peer_chat, [], branch: Examples.Support.branch())

    assert_receive {:peer_message, bob, socket, "hello"}, 1_000

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        get(^bob, :name, "Bob")
        get(^bob, :messages, [[^socket, "hello"]])
        get(^socket, :status, :connected)
        stop(^bob)
      end
  end
end
