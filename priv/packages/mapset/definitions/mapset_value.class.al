@mapset_value
#{super => value, ivars => [#{name => elems}]}.

mapset_value >> init
| Self Args New |
get Args elems List,
ground List -> {list_to_elems List Elems, = New #{class => mapset_value, elems => Elems}} ; = New #{class => mapset_value, elems => List}.

mapset_value >> elem
| Self E |
ground Self,
get Self elems Elems,
get Elems E _.

mapset_value >> elem
| Self E |
not (ground Self),
ground E,
= Self #{class => mapset_value, elems => #{E => true}}.

mapset_value >> members
| Self List |
ground Self,
get Self elems Elems,
findall K List (get Elems K _).

mapset_value >> members
| Self List |
not (ground Self),
list_to_elems List Elems,
= Self #{class => mapset_value, elems => Elems}.

mapset_value >> insert
| Self X New |
get Self elems Elems,
put Elems X true NewElems,
= New #{class => mapset_value, elems => NewElems}.

mapset_value >> union
| Self S New |
get Self elems Elems1,
get S elems Elems2,
findall K List2 (get Elems2 K _),
fold_left List2 map_insert Elems1 Merged,
= New #{class => mapset_value, elems => Merged}.

mapset_value >> intersection
| Self S New |
get Self elems Elems1,
get S elems Elems2,
findall K Common {get Elems1 K _, get Elems2 K _},
list_to_elems Common Merged,
= New #{class => mapset_value, elems => Merged}.