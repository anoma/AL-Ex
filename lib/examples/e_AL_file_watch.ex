defmodule Examples.ALFileWatch do
  @moduledoc "I exercise a live filesystem edge through an ordinary AL object."

  use ExExample
  use AL
  import ExUnit.Assertions

  example file_changes_arrive_as_transactions_on_an_al_object() do
    pid = self()
    path = temporary_path()
    File.write!(path, "initial")

    try do
      {:atomic, {bindings, _constraints, _state}} =
        run(
          ~S"""
          @observed_file_watch
          #{super => file_watch}.

          observed_file_watch >> watching
          | Self |
          call_next_method Self,
          send_elixir HostPid #{event => file_watch_status, status => watching, watcher => Self}.

          observed_file_watch >> receive
          | Self Event |
          get Event contents #{status => ok, value => Contents},
          call_next_method Self Event,
          send_elixir HostPid #{contents => Contents, event => file_changed, watcher => Self}.

          observed_file_watch >> stopped
          | Self |
          call_next_method Self,
          send_elixir HostPid #{event => file_watch_status, status => stopped, watcher => Self}.

          new observed_file_watch #{name => watched_file, path => HostPath} Watcher.
          watch Watcher StartEffect.
          """,
          branch: Examples.Support.branch(),
          bindings: %{"HostPath" => path, "HostPid" => pid}
        )

      watcher = bindings["$Watcher"]
      start_effect = bindings["$StartEffect"]
      assert_receive %{event: :file_watch_status, watcher: ^watcher, status: :watching}, 2_000

      {:atomic, _} =
        run(
          ~S"""
          class HostWatcher observed_file_watch.
          super observed_file_watch file_watch.
          super file_watch object.
          get HostWatcher path HostPath.
          get HostWatcher contents none.
          class HostStartEffect effect.
          get HostStartEffect outcome #{status => ok, value => watching}.
          """,
          branch: Examples.Support.branch(),
          bindings: %{
            "HostPath" => path,
            "HostStartEffect" => start_effect,
            "HostWatcher" => watcher
          }
        )

      File.write!(path, "first")
      assert_receive %{event: :file_changed, watcher: ^watcher, contents: "first"}, 2_000

      File.write!(path, "second")
      assert_receive %{event: :file_changed, watcher: ^watcher, contents: "second"}, 2_000

      {:atomic, {stop_bindings, _constraints, _state}} =
        run(
          ~S"""
          stop_watching HostWatcher StopEffect.
          """,
          branch: Examples.Support.branch(),
          bindings: %{"HostWatcher" => watcher}
        )

      stop_effect = stop_bindings["$StopEffect"]
      assert_receive %{event: :file_watch_status, watcher: ^watcher, status: :stopped}, 2_000

      {:atomic, _} =
        run(
          ~S"""
          class HostStopEffect effect.
          get HostStopEffect outcome #{status => ok, value => stopped}.
          """,
          branch: Examples.Support.branch(),
          bindings: %{"HostStopEffect" => stop_effect}
        )

      File.write!(path, "third")
      refute_receive %{event: :file_changed, watcher: ^watcher, contents: "third"}, 150

      {:atomic, _} =
        run(
          ~S"""
          get HostWatcher contents "second".
          """,
          branch: Examples.Support.branch(),
          bindings: %{"HostWatcher" => watcher}
        )
    after
      File.rm(path)
    end
  end

  defp temporary_path do
    Path.join(System.tmp_dir!(), "al_file_watch_#{System.unique_integer([:positive])}.txt")
  end
end
