defmodule Examples.ALPeer do
  @moduledoc "I connect peers and exchange AL terms."

  use ExExample
  use AL
  import ExUnit.Assertions

  example peers_connect_and_exchange_a_message() do
    pid = self()
    message = %{kind: :greeting, text: "hello", values: [1, 2, {:three, true}]}

    {:atomic, _} =
      run(
        ~S"""
        @observed_peer
        #{super => peer}.

        observed_peer >> receive
        | Self Socket Message |
        call_next_method Self Socket Message,
        = Event #{event => peer_message, message => Message, peer => Self, socket => Socket},
        send_elixir HostPid Event.

        new peer #{name => peer_alice, peer_name => "Alice"} Alice.
        new observed_peer #{name => peer_bob, peer_name => "Bob"} Bob.

        Bob >> listening
        | Self Socket Port |
        call_next_method Self Socket Port,
        connect Alice Self _ _.

        Alice >> connection_established
        | Self Socket |
        call_next_method Self Socket,
        send_message Self Socket HostMessage _.
        """,
        branch: Examples.Support.branch(),
        bindings: %{"HostMessage" => message, "HostPid" => pid}
      )

    assert_receive %{event: :peer_message, peer: :peer_bob, socket: socket, message: ^message},
                   1_000

    {:atomic, _} =
      run(
        ~S"""
        get peer_bob name "Bob".
        get peer_bob messages [[HostSocket, HostMessage]].
        get HostSocket status connected.
        stop peer_alice.
        stop peer_bob.
        """,
        branch: Examples.Support.branch(),
        bindings: %{"HostMessage" => message, "HostSocket" => socket}
      )
  end
end
