Extension {
  #name : :number
}

:number >> :euler_1, [n, sum] [
  findall(candidate, candidates) do
    candidate < n
    candidate > 0
    (candidate = x * 5) or (candidate = x * 3)
    label(candidate)
  end

  sum(candidates, sum)
]
