require 'molinillo'
require 'cocoapods/resolver/lazy_specification'

module Pod
  # The resolver is responsible of generating a list of specifications grouped
  # by target for a given Podfile.
  #
  class Resolver
    # @return [Sandbox] the Sandbox used by the resolver to find external
    #         dependencies.
    #
    attr_reader :sandbox

    # @return [Podfile] the Podfile used by the resolver.
    #
    attr_reader :podfile

    # @return [Array<Dependency>] the list of dependencies locked to a specific
    #         version.
    #
    attr_reader :locked_dependencies

    # @return [Array<Source>] The list of the sources which will be used for
    #         the resolution.
    #
    attr_accessor :sources

    # @param  [Sandbox] sandbox @see sandbox
    # @param  [Podfile] podfile @see podfile
    # @param  [Array<Dependency>] locked_dependencies @see locked_dependencies
    # @param  [Array<Source>, Source] sources @see sources
    #
    def initialize(sandbox, podfile, locked_dependencies, sources)
      @sandbox = sandbox
      @podfile = podfile
      @locked_dependencies = locked_dependencies
      @sources = Array(sources)
    end

    #-------------------------------------------------------------------------#

    public

    # @!group Resolution

    # Identifies the specifications that should be installed.
    #
    # @return [Hash{TargetDefinition => Array<Specification>}] specs_by_target
    #         the specifications that need to be installed grouped by target
    #         definition.
    #
    def resolve
      dependencies = @podfile.target_definition_list.map(&:dependencies).flatten
      @cached_sets = {}
      @activated = Molinillo::Resolver.new(self, self).resolve(dependencies, locked_dependencies)
      specs_by_target
    rescue Molinillo::ResolverError => e
      raise Informative, e.message
    end

    # @return [Hash{Podfile::TargetDefinition => Array<Specification>}]
    #         returns the resolved specifications grouped by target.
    #
    # @note   The returned specifications can be subspecs.
    #
    def specs_by_target
      @specs_by_target ||= begin
        specs_by_target = {}
        podfile.target_definition_list.each do |target|
          specs = target.dependencies.map(&:name).map do |name|
            node = @activated.vertex_named(name)
            (node.recursive_successors << node).to_a
          end
          specs_by_target[target] = specs.
            flatten.
            map(&:payload).
            uniq.
            sort_by(&:name).
            each do |spec|
              validate_platform(spec, target)
              sandbox.store_head_pod(spec.name) if spec.version.head
            end
        end
        specs_by_target
      end
    end

    #-------------------------------------------------------------------------#

    public

    # @!group Specification Provider

    include Molinillo::SpecificationProvider

    # Returns (and caches) the specification that satisfy the given dependency.
    #
    # @return [Array<Specification>] the specifications that satisfy the given
    #   `dependency`.
    #
    # @param  [Dependency] dependency the dependency that is being searched for.
    #
    def search_for(dependency)
      @search ||= {}
      @search[dependency] ||= begin
        specs = find_cached_set(dependency).
          all_specifications.
          select { |s| dependency.requirement.satisfied_by? s.version }.
          map { |s| s.subspec_by_name(dependency.name, false) }.
          compact

        specs.
          reverse.
          each { |s| s.version.head = dependency.head? }
      end
      @search[dependency].dup
    end

    # Returns the dependencies of `specification`.
    #
    # @return [Array<Specification>] all dependencies of `specification`.
    #
    # @param  [Specification] specification the specification whose own
    #         dependencies are being asked for.
    #
    def dependencies_for(specification)
      specification.all_dependencies.map do |dependency|
        if dependency.root_name == Specification.root_name(specification.name)
          Dependency.new(dependency.name, specification.version)
        else
          dependency
        end
      end
    end

    # Returns the name for the given `dependency`.
    #
    # @return [String] the name for the given `dependency`.
    #
    # @param  [Dependency] dependency the dependency whose name is being
    #         queried.
    #
    def name_for(dependency)
      dependency.name
    end

    # @return [String] the user-facing name for a {Podfile}.
    #
    def name_for_explicit_dependency_source
      'Podfile'
    end

    # @return [String] the user-facing name for a {Lockfile}.
    #
    def name_for_locking_dependency_source
      'Podfile.lock'
    end

    # Determines whether the given `requirement` is satisfied by the given
    # `spec`, in the context of the current `activated` dependency graph.
    #
    # @return [Boolean] whether `requirement` is satisfied by `spec` in the
    #         context of the current `activated` dependency graph.
    #
    # @param  [Dependency] requirement the dependency in question.
    #
    # @param  [Molinillo::DependencyGraph] activated the current dependency
    #         graph in the resolution process.
    #
    # @param  [Specification] spec the specification in question.
    #
    def requirement_satisfied_by?(requirement, activated, spec)
      existing_vertices = activated.vertices.values.select do |v|
        Specification.root_name(v.name) ==  requirement.root_name
      end
      existing = existing_vertices.map(&:payload).compact.first
      requirement_satisfied =
        if existing
          existing.version == spec.version && requirement.requirement.satisfied_by?(spec.version)
        else
          requirement.requirement.satisfied_by? spec.version
        end
      requirement_satisfied && !(spec.version.prerelease? && existing_vertices.flat_map(&:requirements).none?(&:prerelease?))
    end

    # Sort dependencies so that the ones that are easiest to resolve are first.
    # Easiest to resolve is (usually) defined by:
    #   1) Is this dependency already activated?
    #   2) How relaxed are the requirements?
    #   3) Are there any conflicts for this dependency?
    #   4) How many possibilities are there to satisfy this dependency?
    #
    # @return [Array<Dependency>] the sorted dependencies.
    #
    # @param  [Array<Dependency>] dependencies the unsorted dependencies.
    #
    # @param  [Molinillo::DependencyGraph] activated the dependency graph of
    #         currently activated specs.
    #
    # @param  [{String => Array<Conflict>}] conflicts the current conflicts.
    #
    def sort_dependencies(dependencies, activated, conflicts)
      dependencies.sort_by do |dependency|
        name = name_for(dependency)
        [
          activated.vertex_named(name).payload ? 0 : 1,
          dependency.prerelease? ? 0 : 1,
          conflicts[name] ? 0 : 1,
          search_for(dependency).count,
        ]
      end
    end

    #-------------------------------------------------------------------------#

    public

    # @!group Resolver UI

    include Molinillo::UI

    include Config::Mixin

    # The UI object the resolver should use for displaying user-facing output.
    #
    # @return [UserInterface] the normal CocoaPods UI object.
    #
    def output
      UI
    end

    # Called before resolution starts. We print out `Resolving dependencies` in
    # the analyzer, so here we just want to print out a starting `.` in verbose
    # mode.
    #
    # @return [Void]
    #
    def before_resolution
      UI.print '.' if config.verbose
    end

    # Called after resolution ends. We don't want to {#indicate_progress}
    # unless in verbose mode, so we only use the default implementation then.
    #
    # @return [Void]
    #
    def after_resolution
      super if config.verbose
    end

    # Called during resolution to indicate progress.
    # We only use the default implementation in verbose mode.
    #
    # @return [Void]
    #
    def indicate_progress
      super if config.verbose
    end

    #-------------------------------------------------------------------------#

    private

    # !@ Resolution context

    # @return [Hash<String => Set>] A cache that keeps tracks of the sets
    #         loaded by the resolution process.
    #
    # @note   Sets store the resolved dependencies and return the highest
    #         available specification found in the sources. This is done
    #         globally and not per target definition because there can be just
    #         one Pod installation, so different version of the same Pods for
    #         target definitions are not allowed.
    #
    attr_accessor :cached_sets

    #-------------------------------------------------------------------------#

    private

    # @!group Private helpers

    # @return [Set] Loads or returns a previously initialized set for the Pod
    #               of the given dependency.
    #
    # @param  [Dependency] dependency
    #         The dependency for which the set is needed.
    #
    # @return [Set] the cached set for a given dependency.
    #
    def find_cached_set(dependency)
      name = dependency.root_name
      unless cached_sets[name]
        if dependency.external_source
          spec = sandbox.specification(name)
          unless spec
            raise StandardError, '[Bug] Unable to find the specification ' \
              "for `#{dependency}`."
          end
          set = Specification::Set::External.new(spec)
        else
          set = create_set_from_sources(dependency)
        end
        cached_sets[name] = set
        unless set
          raise Molinillo::NoSuchDependencyError.new(dependency) # rubocop:disable Style/RaiseArgs
        end
      end
      cached_sets[name]
    end

    # @return [Set] Creates a set for the Pod of the given dependency from the
    #         sources. The set will contain all versions from all sources that
    #         include the Pod.
    #
    # @param  [Dependency] dependency
    #         The dependency for which the set is needed.
    #
    def create_set_from_sources(dependency)
      aggregate.search(dependency)
    end

    # @return [Source::Aggregate] The aggregate of the {#sources}.
    #
    def aggregate
      @aggregate ||= Source::Aggregate.new(sources.map(&:repo))
    end

    # Ensures that a specification is compatible with the platform of a target.
    #
    # @raise  If the specification is not supported by the target.
    #
    # @todo   This step is not specific to the resolution process and should be
    #         performed later in the analysis.
    #
    # @return [void]
    #
    def validate_platform(spec, target)
      unless spec.available_platforms.any? { |p| target.platform.supports?(p) }
        raise Informative, "The platform of the target `#{target.name}` "     \
          "(#{target.platform}) is not compatible with `#{spec}` which has "  \
          "a minimum requirement of #{spec.available_platforms.join(' - ')}."
      end
    end
  end
end
