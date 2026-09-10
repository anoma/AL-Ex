Extension {
  #name : :number
}

:number >> :euler_1, [n, sum] [
  findall(
    candidate,
    [
      candidate < n,
      candidate > 0,
      eq(candidate, x * 5) or eq(candidate, x * 3),
      label(candidate)
    ],
    candidates
  )

  sum(candidates, sum)
]
