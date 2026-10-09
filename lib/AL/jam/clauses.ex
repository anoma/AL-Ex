defmodule AL.JAM.Clauses do
  defp from_stored_body(body) when is_list(body), do: Enum.map(body, &AL.Goal.from_stored/1)
  defp from_stored_body(body), do: body

  # Scan clauses with bodies lifted to structs, so stored form never enters the
  # VM. `def`, not `defp` — `AL.JAM.Relation`'s clause relation uses this too.
  def scan_clauses(object, seq, head, body, branch) do
    AL.Object.scan_oapply(object, seq, head, body, branch)
    |> Enum.map(fn {:oapply, id, s, h, b} -> {:oapply, id, s, h, from_stored_body(b)} end)
  end

  def reflect_clauses(object, seq, head, body, branch) do
    scan_clauses(object, seq, head, AL.Block.goals(body), branch)
    |> Enum.map(fn {:oapply, id, seq, head, body} ->
      {:oapply, id, seq, head, AL.Block.new(body)}
    end)
  end

  # Ground method_id: cacheable, same as providers/3. Var method_id (open
  # query) isn't a stable key — skips the cache.
  def cached_scan_clauses(method_id_pattern, branch) do
    if AL.Var.var?(method_id_pattern) do
      scan_clauses(
        method_id_pattern,
        {:"$var", "seq"},
        {:"$var", "head"},
        {:"$var", "body"},
        branch
      )
    else
      AL.ResolutionCache.fetch_oapply_clauses(branch, method_id_pattern, fn ->
        scan_clauses(
          method_id_pattern,
          {:"$var", "seq"},
          {:"$var", "head"},
          {:"$var", "body"},
          branch
        )
      end)
    end
  end
end
