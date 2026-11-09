@observable_list
#{
  super => object,
  ivars => [#{name => contents, type => list}, #{name => changes, type => list}]
}.

observable_list >> init
| Self Items Self |
set_slots Self #{contents => Items,
                 changes => []}.

observable_list >> insert
| Self Index Item |
get Self contents Before,
isa Prefix list,
length Prefix Index,
concat Prefix Rest Before,
concat Prefix [Item . Rest] After,
set_slots Self #{contents => After,
                 changes => [[add, Index, Item]]}.

observable_list >> remove
| Self Index |
get Self contents Before,
isa Prefix list,
length Prefix Index,
concat Prefix [_ . Rest] Before,
concat Prefix Rest After,
set_slots Self #{contents => After,
                 changes => [[remove, Index]]}.

observable_list >> replace
| Self Items |
set_slots Self #{contents => Items,
                 changes => [[reset, Items]]}.

observable_list >> map
| Self Operation |
get Self contents Items,
map Items Operation Mapped,
replace Self Mapped.