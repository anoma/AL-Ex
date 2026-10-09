defmodule AL.Var.SlotLink do
  def entries(object, :auto, branch) do
    Enum.flat_map([:aos, :soa], fn storage ->
      entries(object, storage, branch)
      |> Enum.filter(fn {owner, key, _} ->
        AL.Dispatch.ivar_storage(owner, key, branch) == storage
      end)
    end)
  end

  def entries(object, :aos, branch) do
    rows =
      if AL.Var.var?(object),
        do: AL.Object.scan_slots(object, AL.Var.var("_"), branch),
        else: AL.Object.read_slots(object, branch)

    for {:slots, owner, slots} <- rows,
        is_map(slots),
        {key, value} <- slots,
        do: {owner, key, value}
  end

  def entries(object, :soa, branch) do
    for {:soa_slot, owner, key, value} <-
          AL.Object.scan_soa_slot(object, AL.Var.var("_"), AL.Var.var("_"), branch),
        do: {owner, key, value}
  end

  def values(object, key, _storage, _branch) when is_map(object) do
    case Map.fetch(object, key) do
      {:ok, value} -> [{object, value}]
      :error -> []
    end
  end

  def values(object, key, :auto, branch) do
    if AL.Var.var?(object) do
      Enum.flat_map([:aos, :soa], fn storage ->
        values(object, key, storage, branch)
        |> Enum.filter(fn {owner, _} ->
          AL.Dispatch.ivar_storage(owner, key, branch) == storage
        end)
      end)
    else
      values(object, key, AL.Dispatch.ivar_storage(object, key, branch), branch)
    end
  end

  def values(object, key, :soa, branch) do
    for {:soa_slot, owner, ^key, value} <-
          AL.Object.scan_soa_slot(object, key, AL.Var.var("_"), branch),
        do: {owner, value}
  end

  def values(object, key, :aos, branch) do
    rows =
      if AL.Var.var?(object),
        do: AL.Object.scan_slots(object, AL.Var.var("_"), branch),
        else: AL.Object.read_slots(object, branch)

    for {:slots, owner, slots} <- rows,
        is_map(slots),
        {:ok, value} <- [Map.fetch(slots, key)],
        do: {owner, value}
  end
end
