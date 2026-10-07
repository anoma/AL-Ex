defmodule ALDefinitionPathTest do
  use ExUnit.Case, async: true

  alias AL.Definition.Path, as: DefinitionPath

  test "owner encodings are distinct safe filenames" do
    owners = [
      :"same/name",
      :"same?name",
      :same,
      "same",
      :.,
      :..,
      :".hidden",
      :"../../outside",
      :""
    ]

    names = Enum.map(owners, &DefinitionPath.filename/1)

    assert length(Enum.uniq(names)) == length(owners)

    for name <- names do
      assert Path.basename(name) == name
      refute String.starts_with?(name, ".")
      assert String.ends_with?(name, ".class.al")
    end

    assert DefinitionPath.filename(:same, :extension) == "same.extension.al"
  end
end
