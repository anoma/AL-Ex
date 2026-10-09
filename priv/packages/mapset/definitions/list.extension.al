list >> list_to_elems
| [] #{} |.

list >> list_to_elems
| [X . Xs] Elems |
list_to_elems Xs Rest,
put Rest X true Elems.