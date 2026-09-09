defmodule AL.TransactionProgram.PackageSystem do
  use AL.TransactionProgram

  @doc false
  def __prepare_program_install__, do: AL.Package.remove_legacy_package_classes()

  defprogram :package_system, version: 6, deps: [:bootstrap] do
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
        :dependency_builds,
        :digest,
        :provider,
        :status
      ],
      redef: true do
      defmethod(:build_package, [self, package]) do
        get_slot(self, :package, package)
      end

      defmethod(:build_version, [self, version]) do
        get_slot(self, :version, version)
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
    end

    defclass :package, super: :class, redef: true do
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
    end

    defmethod(:package, :accepts_build, [self, _provider, _dependencies, self])

    defmethod(:package, :accepts_build, [
      self,
      provider,
      dependencies,
      {self, requirement}
    ]) do
      accepts_requirement(self, provider, dependencies, requirement)
    end

    defclass :package_resolver, metaclass: :object, super: :object, redef: true do
      defmethod(:resolve, [self, providers, requested, solution]) do
        resolve_requirements(self, requested, providers, [], [], solution)
      end
    end

    defmethod(:package_resolver, :requirement_package, [
      _self,
      {package, _requirement},
      package
    ])

    defmethod(:package_resolver, :requirement_package, [_self, package, package])

    defmethod(:package_resolver, :resolve_requirements, [
      _self,
      [],
      _providers,
      _stack,
      selected,
      selected
    ])

    defmethod(:package_resolver, :resolve_requirements, [
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

    defmethod(:package_resolver, :resolve_requirement, [
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

    defmethod(:package_resolver, :resolve_requirement, [
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

    defmethod(:package_resolver, :dependency_providers, [_self, [], _selected, []])

    defmethod(:package_resolver, :dependency_providers, [
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
