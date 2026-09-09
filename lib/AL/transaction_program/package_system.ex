defmodule AL.TransactionProgram.PackageSystem do
  use AL.TransactionProgram

  @doc false
  def __prepare_program_install__, do: AL.Package.remove_legacy_package_classes()

  defprogram :package_system, version: 2, deps: [:bootstrap] do
    defclass :package_build,
      super: :object,
      ivars: [:package, :version, :dependency_builds, :status],
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

      defmethod(:build_status, [self, status]) do
        get_slot(self, :status, status)
      end
    end

    defclass :package, super: :class, redef: true do
      defmethod(:init, [self, args, self]) do
        vm_map_get(args, :deps, deps)
        set_slot(self, :deps, deps)
      end

      defmethod(:deps, [self, deps]) do
        get_slot(self, :deps, deps)
      end

      defmethod(:build, [self, version, dependency_builds, build]) do
        new(
          self,
          %{
            package: self,
            version: version,
            dependency_builds: dependency_builds,
            status: :draft
          },
          build
        )
      end
    end
  end
end
