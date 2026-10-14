defmodule ALViewsWindowManagerTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.TestBranch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    {:ok, branch: branch}
  end

  test "point values expose their coordinates", %{branch: branch} do
    result =
      AL.run(
        ~S"""
        new point #{x => 3, y => 4} Point.
        x Point X.
        y Point Y.
        """,
        branch: branch
      )

    assert %AL{result: {:atomic, {bindings, _, _}}} = result
    assert Map.take(bindings, ["$X", "$Y"]) == %{"$X" => 3, "$Y" => 4}
  end

  test "view values render their fields", %{branch: branch} do
    result =
      AL.run(
        ~S"""
        new phlow_builder #{} Builder.
        text Builder TextClass.
        new TextClass #{title => "Sample", text => "Hello", grammar => "al"} View.
        to_map View Fields.
        """,
        branch: branch
      )

    assert %AL{result: {:atomic, {bindings, _, _}}} = result

    assert bindings["$Fields"] == %{
             priority: 100,
             title: "Sample",
             view: "text",
             text: "Hello",
             grammar: "al"
           }
  end

  test "an empty window manager accepts viewport changes", %{branch: branch} do
    result =
      AL.run(
        ~S"""
        new point #{x => 800, y => 600} Visible.
        new point #{} Total.
        new single_layout #{windows => []} Layout.
        new wm #{layout => Layout, visible_extent => Visible, total_extent => Total} Wm.
        new point #{x => 1200, y => 900} Updated.
        viewport_changed Wm Updated Changed Removed.
        """,
        branch: branch
      )

    assert %AL{result: {:atomic, {bindings, _, _}}} = result
    assert bindings["$Changed"] == []
    assert bindings["$Removed"] == []
  end
end
