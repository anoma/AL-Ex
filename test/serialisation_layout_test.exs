defmodule ALSerialisationLayoutTest do
  use ExUnit.Case, async: true

  alias AL.Serialisation.Layout

  test "distinct owner terms always receive distinct definition paths" do
    root = "/tmp/al-layout"
    branch = AL.Branch.main()

    slash = Layout.definition_path(root, branch, :"same/name")
    question = Layout.definition_path(root, branch, :"same?name")
    atom = Layout.definition_path(root, branch, :same)
    string = Layout.definition_path(root, branch, "same")

    assert MapSet.size(MapSet.new([slash, question, atom, string])) == 4
    assert Path.dirname(slash) == Layout.definitions_dir(root, branch)
  end

  test "branch identities cannot escape the serialisation root" do
    root = "/tmp/al-layout"
    branch = %AL.Branch{id: :"../../outside"}
    directory = Layout.branch_dir(root, branch)
    relative = Path.relative_to(directory, root)

    assert Path.type(relative) == :relative
    refute relative == ".."
    refute String.starts_with?(relative, "../")
  end

  test "definition event filtering observes only class documents below the definitions root" do
    root = "/tmp/al-layout/definitions"

    assert Layout.definition_file?(root, Path.join(root, "card.class.al"))
    refute Layout.definition_file?(root, Path.join(root, "transaction.al"))
    refute Layout.definition_file?(root, root <> "-other/card.class.al")
  end
end
