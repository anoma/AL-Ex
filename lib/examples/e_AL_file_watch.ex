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
          defclass :observed_file_watch,
            super: :file_watch,
            redef: true do
            defmethod(:watching, [self]) do
              call_next_method(self)
              send_elixir(^pid, %{event: :file_watch_status, watcher: self, status: :watching})
            end

            defmethod(:receive, [self, event]) do
              get(event, :contents, %{status: :ok, value: contents})
              call_next_method(self, event)
              send_elixir(^pid, %{event: :file_changed, watcher: self, contents: contents})
            end

            defmethod(:stopped, [self]) do
              call_next_method(self)
              send_elixir(^pid, %{event: :file_watch_status, watcher: self, status: :stopped})
            end
          end

          new(
            :observed_file_watch,
            %{name: :watched_file, path: ^path, redef: true},
            watcher
          )

          watch(watcher, start_effect)
        end

      watcher = bindings[:"$watcher"]
      start_effect = bindings[:"$start_effect"]
      assert_receive %{event: :file_watch_status, watcher: ^watcher, status: :watching}, 2_000

      {:atomic, _} =
        run branch: Examples.Support.branch() do
          class(^watcher, :observed_file_watch)
          super(:observed_file_watch, :file_watch)
          super(:file_watch, :object)
          get(^watcher, :path, ^path)
          get(^watcher, :contents, :none)
          class(^start_effect, :effect)
          get(^start_effect, :outcome, %{status: :ok, value: :watching})
        end

      File.write!(path, "first")
      assert_receive %{event: :file_changed, watcher: ^watcher, contents: "first"}, 2_000

      File.write!(path, "second")
      assert_receive %{event: :file_changed, watcher: ^watcher, contents: "second"}, 2_000

      {:atomic, {stop_bindings, _constraints, _state}} =
        run branch: Examples.Support.branch() do
          stop_watching(^watcher, stop_effect)
        end

      stop_effect = stop_bindings[:"$stop_effect"]
      assert_receive %{event: :file_watch_status, watcher: ^watcher, status: :stopped}, 2_000

      {:atomic, _} =
        run branch: Examples.Support.branch() do
          class(^stop_effect, :effect)
          get(^stop_effect, :outcome, %{status: :ok, value: :stopped})
        end

      File.write!(path, "third")
      refute_receive %{event: :file_changed, watcher: ^watcher, contents: "third"}, 150

      {:atomic, _} =
        run branch: Examples.Support.branch() do
          get(^watcher, :contents, "second")
        end
    after
      File.rm(path)
    end
  end

  defp temporary_path do
    Path.join(System.tmp_dir!(), "al_file_watch_#{System.unique_integer([:positive])}.txt")
  end
end
