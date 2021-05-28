module Ra10ke::Dependencies
  @@version_formats = {}

  # Registers a block that finds the latest version.
  # The block will be called with a list of tags.
  # If the block returns nil the next format will be tried.
  def self.register_version_format(name, &block)
    @@version_formats[name] = block
  end

  # semver is the default version format.
  register_version_format(:semver) do |tags|
    latest_tag = tags.map do |tag|
      begin
        Semverse::Version.new tag[/\Av?(.*)\Z/, 1]
      rescue Semverse::InvalidVersionFormat
        # ignore tags that do not comply to semver
        nil
      end
    end.select { |tag| !tag.nil? }.sort.last.to_s.downcase
    latest_ref = tags.detect { |tag| tag[/\Av?(.*)\Z/, 1] == latest_tag }
  end

  def get_latest_ref(remote_refs)
    tags = remote_refs['tags'].keys
    latest_ref = @@version_formats.detect do |name, block|
      latest_ref = block.call(tags)
      break latest_ref unless latest_ref.nil?
    end
    latest_ref = 'undef (tags do not follow any known pattern)' if latest_ref.nil?
    latest_ref
  end

  def define_task_dependencies(*_args)
    desc "Print outdated forge modules"
    task :dependencies do
      require 'r10k/puppetfile'
      require 'puppet_forge'

      PuppetForge.user_agent = "ra10ke/#{Ra10ke::VERSION}"
      puppetfile = get_puppetfile
      puppetfile.load!
      PuppetForge.host = puppetfile.forge if puppetfile.forge =~ /^http/

      # ignore file allows for "don't tell me about this"
      ignore_modules = []
      if File.exist?('.r10kignore')
        ignore_modules = File.readlines('.r10kignore').each {|l| l.chomp!}
      end

      puppetfile.modules.each do |puppet_module|
        next if ignore_modules.include? puppet_module.title
        if puppet_module.class == R10K::Module::Forge
          module_name = puppet_module.title.gsub('/', '-')
          forge_version = PuppetForge::Module.find(module_name).current_release.version
          installed_version = puppet_module.expected_version
          if installed_version != forge_version
            puts "#{puppet_module.title} is OUTDATED: #{installed_version} vs #{forge_version}"
          end
        end

        if puppet_module.class == R10K::Module::Git
          # use helper; avoid `desired_ref`
          # we do not want to deal with `:control_branch`
          ref = puppet_module.version
          next unless ref

          remote = puppet_module.instance_variable_get(:@remote)
          remote_refs = Git.ls_remote(remote)

          # skip if ref is a branch
          next if remote_refs['branches'].key?(ref)

          if remote_refs['tags'].key?(ref)
            # there are too many possible versioning conventions
            # we have to be be opinionated here
            # so semantic versioning (vX.Y.Z) it is for us
            # as well as support for skipping the leading v letter
            #
            # register own version formats with
            # Ra10ke::Dependencies.register_version_format(:name, &block)
            latest_ref = get_latest_ref(remote_refs)
          elsif ref.match(/^[a-z0-9]{40}$/)
            # for sha just assume head should be tracked
            latest_ref = remote_refs['head'][:sha]
          else
            raise "Unable to determine ref type for #{puppet_module.title}"
          end

          puts "#{puppet_module.title} is OUTDATED: #{ref} vs #{latest_ref}" if ref != latest_ref
        end
      end
    end
  end
end
