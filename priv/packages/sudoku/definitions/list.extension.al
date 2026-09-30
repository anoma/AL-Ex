list >> build_rows
| [] [] |.

list >> build_rows
| [GivenRow . GivenRest] [Row . Rest] |
build_row GivenRow Row,
build_rows GivenRest Rest.

list >> build_row
| [] [] |.

list >> build_row
| [0 . Gs] [Cell . Cs] |
>= Cell 1,
<= Cell 9,
build_row Gs Cs.

list >> build_row
| [N . Gs] [N . Cs] |
> N 0,
build_row Gs Cs.

list >> constrain_rows
| Rows |
each_all_dif Rows,
transpose Rows Cols,
each_all_dif Cols,
boxes Rows Bs,
each_all_dif Bs.

list >> each_all_dif
| [] |.

list >> each_all_dif
| [Group . Rest] |
all_dif Group,
each_all_dif Rest.

list >> boxes
| Rows Boxes |
chunks3 Rows Bands,
bands_boxes Bands BoxGroups,
flatten BoxGroups Boxes.

list >> chunks3
| [] [] |.

list >> chunks3
| [A, B, C . Rest] [[A, B, C] . Chunks] |
chunks3 Rest Chunks.

list >> bands_boxes
| [] [] |.

list >> bands_boxes
| [Band . Bands] [Bs . Rest] |
band_boxes Band Bs,
bands_boxes Bands Rest.

list >> band_boxes
| [R1, R2, R3] [Box1, Box2, Box3] |
chunks3 R1 [A1, A2, A3],
chunks3 R2 [B1, B2, B3],
chunks3 R3 [C1, C2, C3],
concat A1 B1 Ab1,
concat Ab1 C1 Box1,
concat A2 B2 Ab2,
concat Ab2 C2 Box2,
concat A3 B3 Ab3,
concat Ab3 C3 Box3.

list >> label_rows
| [] |.

list >> label_rows
| [Row . Rest] |
label_range Row 1 9,
label_rows Rest.