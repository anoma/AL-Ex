Extension {
  #name : :list
}

:list >> :list_to_elems, [[], %{}] [

]

:list >> :list_to_elems, [[x | xs], elems] [
  list_to_elems(xs, rest)
  put(rest, x, true, elems)
]
