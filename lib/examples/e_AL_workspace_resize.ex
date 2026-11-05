defmodule Examples.ALWorkspaceResize do
  use ExExample
  import ExUnit.Assertions

  def rerun?(_), do: true

  example geometry_and_markup() do
    branch = AL.Branch.fork_stable(%AL.Branch{id: Examples.Support.branch()})

    try do
      initial =
        evaluate(
          ~S"""
          @resize_example_layout
          #{super => single_layout}.

          resize_example_layout >> to_xaml
          | _Self "<Canvas/>" |.

          new point #{x => 800, y => 600} Visible.
          new point #{} Total.
          new resize_example_layout #{windows => []} Layout.
          new wm #{layout => Layout, visible_extent => Visible, total_extent => Total} Wm.
          viewport_changed Wm Visible Changed Removed.
          get Wm xaml Xaml.
          """,
          branch
        )

      assert initial["$Changed"] == []
      assert initial["$Removed"] == []
      assert initial["$Xaml"] == "<Canvas/>"
      wm = initial["$Wm"]

      opened =
        evaluate(
          ~S"""
          new brick_csharp_forward #{target => "resize-example"} Brick.
          new phlow_xaml #{title => "Example", brick => Brick} Content.
          new_window Wm #{on => nil, content => Content} [Window] [].
          """,
          branch,
          %{"Wm" => wm}
        )

      resized =
        evaluate(
          ~S"""
          resize_example_layout >> to_xaml
          | _Self "<Grid/>" |.

          new point #{x => 1200, y => 900} Visible.
          viewport_changed Wm Visible Changed Removed.
          get_slots Wm #{layout => Layout, total_extent => Total, xaml => Xaml, changes => Changes}.
          get Layout windows Windows.
          """,
          branch,
          %{"Wm" => wm}
        )

      assert [window] = resized["$Changed"]
      assert window.id == opened["$Window"].id
      assert window.content == opened["$Content"]
      assert window.extent == resized["$Visible"]
      assert resized["$Total"] == resized["$Visible"]
      assert resized["$Windows"] == [window]
      assert resized["$Removed"] == []
      assert resized["$Xaml"] == "<Canvas/>"

      assert resized["$Changes"] == %{
               changed: [window],
               removed: [],
               extent: resized["$Total"],
               xaml: "<Canvas/>"
             }

      refreshed =
        evaluate(
          ~S"""
          get Wm layout Layout.
          layout_changed Wm Layout Changed Removed.
          get_slots Wm #{xaml => Xaml, changes => Changes}.
          """,
          branch,
          %{"Wm" => wm}
        )

      assert refreshed["$Changed"] == []
      assert refreshed["$Removed"] == []
      assert refreshed["$Xaml"] == "<Grid/>"
      assert refreshed["$Changes"].xaml == refreshed["$Xaml"]

      %{extent: window.extent, resized: resized["$Xaml"], refreshed: refreshed["$Xaml"]}
    after
      AL.Branch.discard(branch)
    end
  end

  defp evaluate(source, branch, bindings \\ %{}) do
    %AL{result: {:atomic, {values, _, _}}} = AL.run(source, branch, bindings: bindings)
    values
  end
end
