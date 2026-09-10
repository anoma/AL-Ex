Extension {
  #name : :list
}

:list >> :build_rows, [[], []] [

]

:list >> :build_rows, [[given_row | given_rest], [row | rest]] [
  build_row(given_row, row)
  build_rows(given_rest, rest)
]

:list >> :build_row, [[], []] [

]

:list >> :build_row, [[0 | gs], [cell | cs]] [
  cell >= 1
  cell <= 9
  build_row(gs, cs)
]

:list >> :build_row, [[n | gs], [n | cs]] [
  n > 0
  build_row(gs, cs)
]

:list >> :constrain_rows, [rows] [
  each_all_dif(rows)
  transpose(rows, cols)
  each_all_dif(cols)
  boxes(rows, bs)
  each_all_dif(bs)
]

:list >> :each_all_dif, [[]] [

]

:list >> :each_all_dif, [[group | rest]] [
  all_dif(group)
  each_all_dif(rest)
]

:list >> :boxes, [rows, boxes] [
  chunks3(rows, bands)
  bands_boxes(bands, box_groups)
  flatten(box_groups, boxes)
]

:list >> :chunks3, [[], []] [

]

:list >> :chunks3, [[a, b, c | rest], [[a, b, c] | chunks]] [
  chunks3(rest, chunks)
]

:list >> :bands_boxes, [[], []] [

]

:list >> :bands_boxes, [[band | bands], [bs | rest]] [
  band_boxes(band, bs)
  bands_boxes(bands, rest)
]

:list >> :band_boxes, [[r1, r2, r3], [box1, box2, box3]] [
  chunks3(r1, [a1, a2, a3])
  chunks3(r2, [b1, b2, b3])
  chunks3(r3, [c1, c2, c3])
  concat(a1, b1, ab1)
  concat(ab1, c1, box1)
  concat(a2, b2, ab2)
  concat(ab2, c2, box2)
  concat(a3, b3, ab3)
  concat(ab3, c3, box3)
]

:list >> :label_rows, [[]] [

]

:list >> :label_rows, [[row | rest]] [
  label_range(row, 1, 9)
  label_rows(rest)
]
