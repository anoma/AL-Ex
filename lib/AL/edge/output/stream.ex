defmodule AL.Edge.Output.Stream do
  use GenServer

  def start_link(device), do: GenServer.start_link(__MODULE__, device)
  def print(pid, text, context), do: GenServer.cast(pid, {:print, text, context})

  @impl GenServer
  def init(device), do: {:ok, device}

  @impl GenServer
  def handle_cast({:print, text, context}, device) do
    Process.group_leader(self(), context.stdout)
    AL.Edge.complete(context, write_text(device, text))
    {:noreply, device}
  end

  defp write_text(device, text) do
    :ok = IO.write(device, text)
    {:ok, byte_size(text)}
  rescue
    exception -> {:error, {:output_error, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:output_error, kind, inspect(reason)}}
  end
end
