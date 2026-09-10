defmodule AL.TransactionProgram.PackageSystem do
  use AL.TransactionProgram

  @doc false
  def __prepare_program_install__, do: AL.Package.remove_legacy_package_classes()

  defprogram :package_system, version: 13, deps: [:bootstrap] do
    defclass :channel,
      super: :object,
      ivars: [:channel_name, :location, :revision],
      redef: true do
      defmethod(:channel_name, [self, name]) do
        get_slot(self, :channel_name, name)
      end

      defmethod(:channel_location, [self, location]) do
        get_slot(self, :location, location)
      end

      defmethod(:channel_revision, [self, revision]) do
        get_slot(self, :revision, revision)
      end
    end

    defclass :package_provider,
      super: :object,
      ivars: [
        :channel,
        :channel_revision,
        :provides,
        :version,
        :requirements,
        :source_digest,
        :source
      ],
      redef: true do
      defmethod(:provider_channel, [self, channel]) do
        get_slot(self, :channel, channel)
      end

      defmethod(:provider_channel_revision, [self, revision]) do
        get_slot(self, :channel_revision, revision)
      end

      defmethod(:provides, [self, package]) do
        get_slot(self, :provides, package)
      end

      defmethod(:provider_version, [self, version]) do
        get_slot(self, :version, version)
      end

      defmethod(:provider_requirements, [self, requirements]) do
        get_slot(self, :requirements, requirements)
      end

      defmethod(:provider_source_digest, [self, digest]) do
        get_slot(self, :source_digest, digest)
      end

      defmethod(:provider_source, [self, source]) do
        get_slot(self, :source, source)
      end
    end

    defclass :package_build,
      super: :object,
      ivars: [
        :package,
        :version,
        :requirements,
        :dependency_builds,
        :digest,
        :provider,
        :status,
        :originated_classes,
        :added_methods,
        :added_superclasses
      ],
      redef: true do
      defmethod(:build_package, [self, package]) do
        get_slot(self, :package, package)
      end

      defmethod(:build_version, [self, version]) do
        get_slot(self, :version, version)
      end

      defmethod(:build_requirements, [self, requirements]) do
        get_slot(self, :requirements, requirements)
      end

      defmethod(:dependency_builds, [self, dependency_builds]) do
        get_slot(self, :dependency_builds, dependency_builds)
      end

      defmethod(:build_digest, [self, digest]) do
        get_slot(self, :digest, digest)
      end

      defmethod(:build_provider, [self, provider]) do
        get_slot(self, :provider, provider)
      end

      defmethod(:build_status, [self, status]) do
        get_slot(self, :status, status)
      end

      defmethod(:originated_classes, [self, classes]) do
        get_slot(self, :originated_classes, classes)
      end

      defmethod(:added_methods, [self, methods]) do
        get_slot(self, :added_methods, methods)
      end

      defmethod(:added_superclasses, [self, superclasses]) do
        get_slot(self, :added_superclasses, superclasses)
      end

      defmethod(:originates_class, [self, class]) do
        originated_classes(self, classes)
        member(classes, class)
      end

      defmethod(:adds_method, [self, owner, selector]) do
        added_methods(self, methods)
        member(methods, [owner, selector])
      end

      defmethod(:adds_superclass, [self, owner, superclass]) do
        added_superclasses(self, superclasses)
        member(superclasses, [owner, superclass])
      end

      defmethod(:include_method, [self, owner, selector]) do
        build_status(self, :open)
        vm_method(owner, selector, _method)
        include_contribution(self, :added_methods, [owner, selector])
      end

      defmethod(:include_superclass, [self, owner, superclass]) do
        build_status(self, :open)
        super(owner, superclass)
        include_contribution(self, :added_superclasses, [owner, superclass])
      end

      defmethod(:include_class, [self, owner]) do
        build_status(self, :open)
        class(owner, _metaclass)
        include_contribution(self, :originated_classes, owner)
        findall(selector, [vm_method(owner, selector, _method)], selectors)

        forall([member(selectors, selector)]) do
          include_method(self, owner, selector)
        end

        findall(superclass, [super(owner, superclass)], superclasses)

        forall([member(superclasses, superclass)]) do
          include_superclass(self, owner, superclass)
        end
      end

      defmethod(:include_contribution, [self, slot, contribution]) do
        get_slot(self, slot, contributions)
        member(contributions, contribution)
      end

      defmethod(:include_contribution, [self, slot, contribution]) do
        get_slot(self, slot, contributions)
        not [member(contributions, contribution)]
        concat(contributions, [contribution], updated)
        set_slot(self, slot, updated)
      end

      defmethod(:contribution_owners, [_self, [], owners, owners])

      defmethod(:contribution_owners, [self, [[owner, _] | rest], seen, owners]) do
        member(seen, owner)
        contribution_owners(self, rest, seen, owners)
      end

      defmethod(:contribution_owners, [self, [[owner, _] | rest], seen, owners]) do
        not [member(seen, owner)]
        contribution_owners(self, rest, [owner | seen], owners)
      end

      defmethod(:extends_class, [self, class]) do
        added_methods(self, methods)
        added_superclasses(self, superclasses)
        concat(methods, superclasses, contributions)
        contribution_owners(self, contributions, [], owners)
        member(owners, class)
        not [originates_class(self, class)]
      end
    end

    defclass :package, super: :class, ivars: [:active_build], redef: true do
      defmethod(:allocate, [self, args, name]) do
        put_new(args, :super, :package_build, package_args)
        call_next_method(self, package_args, name)
      end

      defmethod(:init, [self, args, self]) do
        get(args, :open_build, false)
      end

      defmethod(:init, [self, args, self]) do
        get(args, :open_build, true, true)
        get(args, :version, 1, version)
        get(args, :deps, [], requirements)
        active_dependency_builds(self, requirements, dependency_builds)

        build(
          self,
          %{
            package: self,
            version: version,
            requirements: requirements,
            dependency_builds: dependency_builds,
            status: :open,
            originated_classes: [],
            added_methods: [],
            added_superclasses: []
          },
          open_build
        )

        set_slot(self, :active_build, open_build)
      end

      defmethod(:active_build, [self, build]) do
        get_slot(self, :active_build, build)
      end

      defmethod(:build, [self, specification, build]) do
        new(self, specification, build)
      end

      defmethod(:provider_for, [self, providers, _requirement, provider]) do
        member(providers, provider)
        provides(provider, self)
      end

      defmethod(:requirements_for, [_self, provider, requirements]) do
        provider_requirements(provider, requirements)
      end

      defmethod(:accepts_requirement, [_self, _provider, _dependencies, :any]) do
        pass
      end

      defmethod(:accepts_build, [self, _provider, _dependencies, self])

      defmethod(:accepts_build, [
        self,
        provider,
        dependencies,
        {self, requirement}
      ]) do
        accepts_requirement(self, provider, dependencies, requirement)
      end

      defmethod(:active_dependency_builds, [_self, [], []])

      defmethod(:active_dependency_builds, [self, [requirement | rest], dependencies]) do
        requirement_package(:package_resolver, requirement, package)
        active_build(package, build)
        active_dependency_builds(self, rest, remaining)
        unify(dependencies, [{package, build} | remaining])
      end
    end

    defclass :package_resolver, metaclass: :object, super: :object, redef: true do
      defmethod(:resolve, [self, providers, requested, solution]) do
        resolve_requirements(self, requested, providers, [], [], solution)
      end

      defmethod(:requirement_package, [
        _self,
        {package, _requirement},
        package
      ])

      defmethod(:requirement_package, [_self, package, package])

      defmethod(:resolve_requirements, [
        _self,
        [],
        _providers,
        _stack,
        selected,
        selected
      ])

      defmethod(:resolve_requirements, [
        self,
        [requirement | rest],
        providers,
        stack,
        selected_before,
        selected
      ]) do
        resolve_requirement(
          self,
          requirement,
          providers,
          stack,
          selected_before,
          selected_after_requirement
        )

        resolve_requirements(
          self,
          rest,
          providers,
          stack,
          selected_after_requirement,
          selected
        )
      end

      defmethod(:resolve_requirement, [
        _self,
        requirement,
        _providers,
        _stack,
        selected,
        selected
      ]) do
        requirement_package(_self, requirement, package)
        member(selected, [package, provider, dependencies])
        accepts_build(package, provider, dependencies, requirement)
      end

      defmethod(:resolve_requirement, [
        self,
        requirement,
        providers,
        stack,
        selected_before,
        selected
      ]) do
        requirement_package(self, requirement, package)
        not [member(selected_before, [package, _provider, _dependencies])]
        not [member(stack, package)]
        provider_for(package, providers, requirement, provider)
        requirements_for(package, provider, requirements)

        resolve_requirements(
          self,
          requirements,
          providers,
          [package | stack],
          selected_before,
          selected_with_dependencies
        )

        dependency_providers(self, requirements, selected_with_dependencies, dependencies)
        accepts_build(package, provider, dependencies, requirement)
        concat(selected_with_dependencies, [[package, provider, dependencies]], selected)
      end

      defmethod(:dependency_providers, [_self, [], _selected, []])

      defmethod(:dependency_providers, [
        self,
        [requirement | rest],
        selected,
        [{requirement, package, provider} | dependencies]
      ]) do
        requirement_package(self, requirement, package)
        member(selected, [package, provider, _dependency_dependencies])
        dependency_providers(self, rest, selected, dependencies)
      end
    end
  end
end
