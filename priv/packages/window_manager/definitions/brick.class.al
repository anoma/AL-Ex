@brick
#{super => object}.

brick >> to_xaml
  | Self Text |
xaml_tag Self Tag,
inheritance_chain Self Chain,
collect_ivar_specs Chain Specs,
findall Spec XamlSpecs {
  member Specs Spec,
  get Spec xaml _
},
lambda [Spec, Property] Render {
  get_slots Spec #{xaml => Renderer},
  new Renderer #{owner => Self, spec => Spec} View,
  xaml_property View Property
},
map XamlSpecs Render Properties,
join Properties Body,
format "<~a>~a</~a>" [Tag, Body, Tag] Text.