Extension {
  #name : :number
}

:number >> :euler_1, [n, sum] [
  findall(
    candidate,
    [
      candidate < n,
      candidate > 0,
      (candidate = x * 5) or (candidate = x * 3),
      label(candidate)
    ],
    candidates
  )

  sum(candidates, sum)
]
