defmodule Examples.ALPeer do
  @moduledoc "I connect peers and exchange AL terms."

  use ExExample
  use AL
  import ExUnit.Assertions

  example peers_connect_and_exchange_a_message() do
    pid = self()
    message = %{kind: :greeting, text: "hello", values: [1, 2, {:three, true}]}

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        defclass :observed_peer, super: :peer, redef: true do
          defmethod(:receive, [self, socket, message]) do
            call_next_method(self, socket, message)
            functor(event, :peer_message, [self, socket, message])
            send_elixir(^pid, event)
          end
        end

        new(:peer, %{name: :peer_alice, peer_name: "Alice"}, alice)
        new(:observed_peer, %{name: :peer_bob, peer_name: "Bob"}, bob)

        defmethod(bob, :listening, [self, socket, port]) do
          call_next_method(self, socket, port)
          connect(alice, self, _, _)
        end

        defmethod(alice, :connection_established, [self, socket]) do
          call_next_method(self, socket)
          send_message(self, socket, ^message, _)
        end
      end

    assert_receive {:peer_message, :peer_bob, socket, ^message}, 1_000

    {:atomic, _} =
      run branch: Examples.Support.branch() do
        get(:peer_bob, :name, "Bob")
        get(:peer_bob, :messages, [[^socket, ^message]])
        get(^socket, :status, :connected)
        stop(:peer_alice)
        stop(:peer_bob)
      end
  end
end
