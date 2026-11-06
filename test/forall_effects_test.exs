defmodule AL.ForallEffectsTest do
  use ExUnit.Case, async: false

  test "creates and runs one effect for each condition answer" do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)

    directory =
      Path.join(System.tmp_dir!(), "al_forall_effects_#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    values = ["first", "second", "third"]

    paths =
      Enum.map(values, fn value ->
        path = Path.join(directory, value)
        File.write!(path, value)
        path
      end)

    assert %AL{result: {:atomic, {bindings, _, _}}} =
             AL.run(
               ~S"""
               @forall_effect_log #{super => object, ivars => [#{name => effects}]}.
               new forall_effect_log #{effects => []} Log.
               forall {member Paths Path} {
                 new effect #{arguments => [Path], operation => read, provider => file} Effect,
                 get Log effects Existing,
                 concat Existing [Effect] Updated,
                 set_slot Log effects Updated
               }.
               get Log effects Effects.
               """,
               branch,
               bindings: %{"Paths" => paths}
             )

    effects = bindings["$Effects"]
    assert length(effects) == 3
    assert length(Enum.uniq(effects)) == 3

    Enum.zip(effects, values)
    |> Enum.each(fn {effect, value} ->
      assert {:ok, ^value} = AL.await_effect(effect, branch: branch, timeout: 1000)
    end)
  end
end
