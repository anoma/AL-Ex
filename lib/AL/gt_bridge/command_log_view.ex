defmodule AL.GtBridge.CommandLogView do
  use TypedStruct

  typedstruct enforce: true do
    field(:title, String.t(), enforce: true)
    field(:priority, integer(), default: 10)
    field(:rows, list(), enforce: true)
  end

  def as_dict(view) do
    formatted_items =
      Enum.map(view.rows, fn row ->
        [row.marker, to_string(row.time), to_string(row.tx), row.command]
      end)

    %{
      title: view.title,
      priority: view.priority,
      viewName: "ALCommandLogViewSpecification",
      dataTransport: 2,
      itemsCount: length(view.rows),
      columns: Enum.map(["", "Time", "Tx", "Command"], &%{title: &1}),
      items: formatted_items,
      rawItems: Enum.map(view.rows, & &1.operation),
      colors: Enum.map(view.rows, & &1.color)
    }
  end
end
