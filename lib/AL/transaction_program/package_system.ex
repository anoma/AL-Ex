defmodule AL.TransactionProgram.PackageSystem do
  use AL.TransactionProgram

  @doc false
  def __prepare_program_install__, do: AL.Package.remove_legacy_package_classes()

  defprogram :package_system, version: 3, deps: [:bootstrap] do
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

    defclass :package_build,
      super: :object,
      ivars: [
        :package,
        :version,
        :dependency_builds,
        :digest,
        :channel,
        :channel_revision,
        :source,
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

      defmethod(:build_channel, [self, channel]) do
        get_slot(self, :channel, channel)
      end

      defmethod(:build_channel_revision, [self, revision]) do
        get_slot(self, :channel_revision, revision)
      end

      defmethod(:build_source, [self, source]) do
        get_slot(self, :source, source)
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
    end
  end
end
