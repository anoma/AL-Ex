defmodule AL.Runner.FutureTransaction do
  def execute(future, branch) do
    lineage = AL.Record.lineage_from_completion(future, branch)

    result =
      AL.eval(
        [%AL.Goal.Send{object: future, method: :run, args: []}],
        nil,
        branch,
        Map.to_list(lineage)
      )
      |> AL.post_commit()

    completion = AL.Runner.Result.future(future, result)
    method = if match?({:aborted, _}, completion.result), do: :failed, else: :complete

    opts =
      if is_atom(result.handle), do: AL.Record.lineage(result.handle, branch), else: lineage

    AL.Edge.notify(
      future,
      method,
      [AL.Runner.Result.to_stored(completion)],
      branch,
      Map.to_list(opts)
    )
  end
end
