@brick
#{super => object}.

brick >> to_xaml
| Self Text |
xaml_tag Self Tag,
inheritance_chain Self Chain,
collect_ivar_specs Chain Specs,
index_specs Self Specs ByName,
map_pairs ByName Pairs,
findall Spec XamlSpecs {member Pairs [_Name, Spec], get Spec xaml _},
lambda [Spec, Property] Render {
  get_slots Spec #{xaml => Renderer},
  new Renderer #{owner => Self, spec => Spec} View,
  to_xaml View Property
},
map XamlSpecs Render Properties,
join Properties Body,
format "<~a>~a</~a>" [Tag, Body, Tag] Text,
cut.

brick >> init
| Self Args Self |
call_next_method Self Args Self,
cut.

brick >> index_specs
| _Self Specs ByName |
lambda [Index, Spec, Next] Add {get Spec name Name, put Index Name Spec Next},
fold_right Specs Add #{} ByName.

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
