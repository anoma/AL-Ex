defmodule Examples.ALFileWatch do
  @moduledoc "I exercise a live filesystem edge through an ordinary AL object."

  use ExExample
  use AL
  import ExUnit.Assertions

  example file_changes_arrive_as_transactions_on_an_al_object() do
    path = temporary_path()
    File.write!(path, "initial")

    try do
      {:atomic, {bindings, _state}} =
        run branch: Examples.Support.branch() do
          new(
            :file_watch,
            %{name: :watched_file, path: ^path, redef: true},
            watcher
          )

          watch(watcher, start_effect)
        end

      watcher = bindings[:"$watcher"]
      start_effect = bindings[:"$start_effect"]
      await_status(watcher, :watching)

      {:atomic, _} =
        run branch: Examples.Support.branch() do
          class(^watcher, :file_watch)
          super(:file_watch, :object)
          get(^watcher, :path, ^path)
          get(^watcher, :contents, :none)
          class(^start_effect, :effect)
          get(^start_effect, :outcome, {:ok, :watching})
        end

      File.write!(path, "first")
      await_contents(watcher, "first")

      File.write!(path, "second")
      await_contents(watcher, "second")

      {:atomic, {stop_bindings, _state}} =
        run branch: Examples.Support.branch() do
          stop_watching(^watcher, stop_effect)
        end

      stop_effect = stop_bindings[:"$stop_effect"]
      await_status(watcher, :stopped)

      {:atomic, _} =
        run branch: Examples.Support.branch() do
          class(^stop_effect, :effect)
          get(^stop_effect, :outcome, {:ok, :stopped})
        end

      File.write!(path, "third")
      Process.sleep(150)

      {:atomic, _} =
        run branch: Examples.Support.branch() do
          get(^watcher, :contents, "second")
        end
    after
      File.rm(path)
    end
  end

  defp await_contents(watcher, contents) do
    await(watcher, :contents, contents, "file watch did not retain new contents")
  end

  defp await_status(watcher, status) do
    await(watcher, :status, status, "file watch did not reach expected status")
  end

  defp await(watcher, slot, value, message) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    await(watcher, slot, value, message, deadline)
  end

  defp await(watcher, slot, value, message, deadline) do
    result =
      run branch: Examples.Support.branch() do
        get(^watcher, ^slot, ^value)
      end

    case result do
      {:atomic, _result} ->
        value

      _failed ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          await(watcher, slot, value, message, deadline)
        else
          flunk("#{message}: #{inspect(value)}")
        end
    end
  end

  defp temporary_path do
    Path.join(System.tmp_dir!(), "al_file_watch_#{System.unique_integer([:positive])}.txt")
  end
end
