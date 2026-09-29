@process
#{super => object, ivars => [#{name => pid}]}.

process >> allocate
| Self Args NewObj |
class Self Meta,
get Args name NewObj,
vm_set_class NewObj Meta,
vm_set_super NewObj object.

process >> init
| Self Args Self |
get Args pid Pid,
set_slot Self pid Pid.