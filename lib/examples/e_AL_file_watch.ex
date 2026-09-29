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
        run branch: Examples.Support.branch() do
          ~AL"""
          @observed_file_watch
          #{super => file_watch}.

          observed_file_watch >> watching
          | Self |
          call_next_method Self,
          send_elixir ^pid #{event => file_watch_status, status => watching, watcher => Self}.

          observed_file_watch >> receive
          | Self Event |
          get Event contents #{status => ok, value => Contents},
          call_next_method Self Event,
          send_elixir ^pid #{contents => Contents, event => file_changed, watcher => Self}.

          observed_file_watch >> stopped
          | Self |
          call_next_method Self,
          send_elixir ^pid #{event => file_watch_status, status => stopped, watcher => Self}.

          new observed_file_watch #{name => watched_file, path => ^path} Watcher.
          watch Watcher StartEffect.
          """
        end

      watcher = bindings[:"$Watcher"]
      start_effect = bindings[:"$StartEffect"]
      assert_receive %{event: :file_watch_status, watcher: ^watcher, status: :watching}, 2_000

      {:atomic, _} =
        run branch: Examples.Support.branch() do
          ~AL"""
          class ^watcher observed_file_watch.
          super observed_file_watch file_watch.
          super file_watch object.
          get ^watcher path ^path.
          get ^watcher contents none.
          class ^start_effect effect.
          get ^start_effect outcome #{status => ok, value => watching}.
          """
        end

      File.write!(path, "first")
      assert_receive %{event: :file_changed, watcher: ^watcher, contents: "first"}, 2_000

      File.write!(path, "second")
      assert_receive %{event: :file_changed, watcher: ^watcher, contents: "second"}, 2_000

      {:atomic, {stop_bindings, _constraints, _state}} =
        run branch: Examples.Support.branch() do
          ~AL"""
          stop_watching ^watcher StopEffect.
          """
        end

      stop_effect = stop_bindings[:"$StopEffect"]
      assert_receive %{event: :file_watch_status, watcher: ^watcher, status: :stopped}, 2_000

      {:atomic, _} =
        run branch: Examples.Support.branch() do
          ~AL"""
          class ^stop_effect effect.
          get ^stop_effect outcome #{status => ok, value => stopped}.
          """
        end

      File.write!(path, "third")
      refute_receive %{event: :file_changed, watcher: ^watcher, contents: "third"}, 150

      {:atomic, _} =
        run branch: Examples.Support.branch() do
          ~AL"""
          get ^watcher contents "second".
          """
        end
    after
      File.rm(path)
    end
  end

  defp temporary_path do
    Path.join(System.tmp_dir!(), "al_file_watch_#{System.unique_integer([:positive])}.txt")
  end
end
