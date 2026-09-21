Extension {
  #name : :list
}

:list >> :combos, [[], [[]]] [

]

:list >> :combos, [[xs | xss], result] [
  combos(xss, rest_combos)
  findall([x | rest], result) do
    member(xs, x)
    member(rest_combos, rest)
  end
]
