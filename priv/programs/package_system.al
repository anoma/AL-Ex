defprogram package_system #{deps: [bootstrap], version: 14}.

@channel
#{
  super: object,
  ivars: [#{name: channel_name}, #{name: location}, #{name: revision}]
}.

channel >> channel_name
| Self Name |
get Self channel_name Name.

channel >> channel_location
| Self Location |
get Self location Location.

channel >> channel_revision
| Self Revision |
get Self revision Revision.

@package_provider
#{
  super: object,
  ivars: [
    #{name: channel},
    #{name: channel_revision},
    #{name: provides},
    #{name: version},
    #{name: requirements},
    #{name: source_digest},
    #{name: source}
  ]
}.

package_provider >> provider_channel
| Self Channel |
get Self channel Channel.

package_provider >> provider_channel_revision
| Self Revision |
get Self channel_revision Revision.

package_provider >> provides
| Self Package |
get Self provides Package.

package_provider >> provider_version
| Self Version |
get Self version Version.

package_provider >> provider_requirements
| Self Requirements |
get Self requirements Requirements.

package_provider >> provider_source_digest
| Self Digest |
get Self source_digest Digest.

package_provider >> provider_source
| Self Source |
get Self source Source.

@package_build
#{
  super: object,
  ivars: [
    #{name: package},
    #{name: version},
    #{name: requirements},
    #{name: dependency_builds},
    #{name: digest},
    #{name: provider},
    #{name: status},
    #{name: originated_classes},
    #{name: added_methods},
    #{name: added_superclasses}
  ]
}.

package_build >> build_package
| Self Package |
get Self package Package.

package_build >> build_version
| Self Version |
get Self version Version.

package_build >> build_requirements
| Self Requirements |
get Self requirements Requirements.

package_build >> dependency_builds
| Self DependencyBuilds |
get Self dependency_builds DependencyBuilds.

package_build >> build_digest
| Self Digest |
get Self digest Digest.

package_build >> build_provider
| Self Provider |
get Self provider Provider.

package_build >> build_status
| Self Status |
get Self status Status.

package_build >> originated_classes
| Self Classes |
get Self originated_classes Classes.

package_build >> added_methods
| Self Methods |
get Self added_methods Methods.

package_build >> added_superclasses
| Self Superclasses |
get Self added_superclasses Superclasses.

package_build >> originates_class
| Self Class |
originated_classes Self Classes,
member Classes Class.

package_build >> adds_method
| Self Owner Selector |
added_methods Self Methods,
member Methods [Owner, Selector].

package_build >> adds_superclass
| Self Owner Superclass |
added_superclasses Self Superclasses,
member Superclasses [Owner, Superclass].

package_build >> include_method
| Self Owner Selector |
build_status Self open,
method Owner Selector _Method,
include_contribution Self added_methods [Owner, Selector].

package_build >> include_superclass
| Self Owner Superclass |
build_status Self open,
super Owner Superclass,
include_contribution Self added_superclasses [Owner, Superclass].

package_build >> include_class
| Self Owner |
build_status Self open,
class Owner _Metaclass,
include_contribution Self originated_classes Owner,
findall Selector Selectors {method Owner Selector _Method},
forall {member Selectors Selector} {include_method Self Owner Selector},
findall Superclass Superclasses {super Owner Superclass},
forall {member Superclasses Superclass} {include_superclass Self Owner Superclass}.

package_build >> include_contribution
| Self Slot Contribution |
get Self Slot Contributions,
member Contributions Contribution.

package_build >> include_contribution
| Self Slot Contribution |
get Self Slot Contributions,
not {member Contributions Contribution},
concat Contributions [Contribution] Updated,
set_slot Self Slot Updated.

package_build >> contribution_owners
| _Self [] Owners Owners |.

package_build >> contribution_owners
| Self [[Owner, _] . Rest] Seen Owners |
member Seen Owner,
contribution_owners Self Rest Seen Owners.

package_build >> contribution_owners
| Self [[Owner, _] . Rest] Seen Owners |
not {member Seen Owner},
contribution_owners Self Rest [Owner . Seen] Owners.

package_build >> extends_class
| Self Class |
added_methods Self Methods,
added_superclasses Self Superclasses,
concat Methods Superclasses Contributions,
contribution_owners Self Contributions [] Owners,
member Owners Class,
not {originates_class Self Class}.

@package
#{super: class, ivars: [#{name: active_build}]}.

package >> allocate
| Self Args Name |
put_new Args super package_build PackageArgs,
call_next_method Self PackageArgs Name.

package >> init
| Self Args Self |
get Args open_build false.

package >> init
| Self Args Self |
get Args open_build true true,
get Args version 1 Version,
get Args deps [] Requirements,
active_dependency_builds Self Requirements DependencyBuilds,
build Self #{
  added_methods: [],
  added_superclasses: [],
  dependency_builds: DependencyBuilds,
  originated_classes: [],
  package: Self,
  requirements: Requirements,
  status: open,
  version: Version
} OpenBuild,
set_slot Self active_build OpenBuild.

package >> active_build
| Self Build |
get Self active_build Build.

package >> build
| Self Specification Build |
new Self Specification Build.

package >> provider_for
| Self Providers _Requirement Provider |
member Providers Provider,
provides Provider Self.

package >> requirements_for
| _Self Provider Requirements |
provider_requirements Provider Requirements.

package >> accepts_requirement
| _Self _Provider _Dependencies any |
pass.

package >> accepts_build
| Self _Provider _Dependencies Self |.

package >> accepts_build
| Self Provider Dependencies #{package: Self, requirement: Requirement} |
accepts_requirement Self Provider Dependencies Requirement.

package >> active_dependency_builds
| _Self [] [] |.

package >> active_dependency_builds
| Self [Requirement . Rest] Dependencies |
requirement_package package_resolver Requirement Package,
active_build Package Build,
active_dependency_builds Self Rest Remaining,
Dependencies = [#{build: Build, package: Package} . Remaining].

@package_resolver
#{super: object, metaclass: object}.

package_resolver >> resolve
| Self Providers Requested Solution |
resolve_requirements Self Requested Providers [] [] Solution.

package_resolver >> requirement_package
| _Self #{package: Package, requirement: _Requirement} Package |.

package_resolver >> requirement_package
| _Self Package Package |.

package_resolver >> resolve_requirements
| _Self [] _Providers _Stack Selected Selected |.

package_resolver >> resolve_requirements
| Self [Requirement . Rest] Providers Stack SelectedBefore Selected |
resolve_requirement Self Requirement Providers Stack SelectedBefore SelectedAfterRequirement,
resolve_requirements Self Rest Providers Stack SelectedAfterRequirement Selected.

package_resolver >> resolve_requirement
| _Self Requirement _Providers _Stack Selected Selected |
requirement_package _Self Requirement Package,
member Selected [Package, Provider, Dependencies],
accepts_build Package Provider Dependencies Requirement.

package_resolver >> resolve_requirement
| Self Requirement Providers Stack SelectedBefore Selected |
requirement_package Self Requirement Package,
not {member SelectedBefore [Package, _Provider, _Dependencies]},
not {member Stack Package},
provider_for Package Providers Requirement Provider,
requirements_for Package Provider Requirements,
resolve_requirements Self Requirements Providers [Package . Stack] SelectedBefore SelectedWithDependencies,
dependency_providers Self Requirements SelectedWithDependencies Dependencies,
accepts_build Package Provider Dependencies Requirement,
concat SelectedWithDependencies [[Package, Provider, Dependencies]] Selected.

package_resolver >> dependency_providers
| _Self [] _Selected [] |.

package_resolver >> dependency_providers
| Self [Requirement . Rest] Selected [
  #{package: Package, provider: Provider, requirement: Requirement} . Dependencies
] |
requirement_package Self Requirement Package,
member Selected [Package, Provider, _DependencyDependencies],
dependency_providers Self Rest Selected Dependencies.
