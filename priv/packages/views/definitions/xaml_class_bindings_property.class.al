@xaml_class_bindings_property
#{super => xaml_property}.

xaml_class_bindings_property >> to_xaml
| Self Text |
slot_value Self Bindings,
findall Part Parts {
  get Bindings Name Binding,
  atom_string Name Raw,
  xml_escape Self Raw Escaped,
  to_xaml Binding Content,
  format "<Classes.~a>~a</Classes.~a>" [Escaped, Content, Escaped] Part
},
join Parts Text.
