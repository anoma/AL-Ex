@brick
#{super => object}.

brick >> to_xaml
| Self Text |
xaml_tag Self Tag,
vm_cached_ivar_specs Self Inherited,
collect_ivar_specs [Self] Own,
concat Own Inherited Specs,
index_specs Self Specs ByName,
map_pairs ByName Pairs,
properties_xaml Self Pairs Properties,
join Properties Body,
format "<~a>~a</~a>" [Tag, Body, Tag] Text,
cut.

brick >> init
| Self Args Self |
call_next_method Self Args Self,
cut.

brick >> index_specs
| _Self [] #{} |.

brick >> index_specs
| Self [Spec . Rest] ByName |
index_specs Self Rest Tail,
get Spec name Name,
put Tail Name Spec ByName.

brick >> init_value
| Self Class Args Specs Value |
index_specs Self Specs ByName,
map_pairs ByName Pairs,
initial_fields Self Args Pairs Fields,
put Fields class Class Value,
cut.

brick >> apply_ivar_spec
| Self Args Spec Name Value |
get Spec name Name,
initial_value Self Args Spec Value -> validate_ivar_spec Self Spec Name Value ; pass.

brick >> initial_fields
| _Self _Args [] #{} |.

brick >> initial_fields
| Self Args [[Name, Spec] . Rest] Fields |
initial_fields Self Args Rest Tail,
initial_value Self Args Spec Value -> {validate_ivar_spec Self Spec Name Value, put Tail Name Value Fields} ; = Fields Tail.

brick >> initial_value
| _Self Args Spec Value |
get Spec name Name,
get Args Name Value.

brick >> initial_value
| _Self Args Spec Value |
get Spec name Name,
not (get Args Name _),
get Spec default Value.

brick >> validate_ivar_type
| Self Spec Value |
call_next_method Self Spec Value,
get Spec element_type Type -> freeze Value (elements_are Self Value Type) ; pass.

brick >> elements_are
| _Self [] _Type |.

brick >> elements_are
| Self [Element . Rest] Type |
isa Element Type,
freeze Rest (elements_are Self Rest Type).

brick >> properties_xaml
| _Self [] [] |.

brick >> properties_xaml
| Self [[Name, Spec] . Rest] Properties |
{
  get Spec xaml Renderer,
  get Self Name Value -> pass ; get Spec default Value
} -> {
  new Renderer #{owner => Self, spec => Spec} View,
  render View Value Property,
  = Properties [Property . Tail],
  properties_xaml Self Rest Tail
} ; properties_xaml Self Rest Properties.