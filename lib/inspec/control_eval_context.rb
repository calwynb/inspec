# encoding: utf-8
# author: Dominik Richter
# author: Christoph Hartmann
require 'inspec/dsl'
require 'inspec/dsl_shared'

module Inspec
  #
  # ControlEvalContext constructs an anonymous class that control
  # files will be instance_exec'd against.
  #
  # The anonymous class includes the given passed resource_dsl as well
  # as the basic DSL of the control files (describe, control, title,
  # etc).
  #
  class ControlEvalContext
    # Create the context for controls. This includes all components of the DSL,
    # including matchers and resources.
    #
    # @param [ResourcesDSL] resources_dsl which has all resources to attach
    # @return [RuleContext] the inner context of rules
    def self.rule_context(resources_dsl, profile_id)
      require 'rspec/core/dsl'
      Class.new(Inspec::Rule) do
        include RSpec::Core::DSL
        with_resource_dsl resources_dsl

        # allow attributes to be accessed within control blocks
        define_method :attribute do |name|
          Inspec::AttributeRegistry.find_attribute(name, profile_id).value
        end
      end
    end

    # Creates the heart of the control eval context:
    #
    # An instantiated object which has all resources registered to it
    # and exposes them to the a test file.
    #
    # @param profile_context [Inspec::ProfileContext]
    # @param outer_dsl [OuterDSLClass]
    # @return [ProfileContextClass]
    def self.create(profile_context, resources_dsl) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      profile_context_owner = profile_context
      profile_id = profile_context.profile_id
      rule_class = rule_context(resources_dsl, profile_id)

      Class.new do # rubocop:disable Metrics/BlockLength
        include Inspec::DSL
        include Inspec::DSL::RequireOverride
        include resources_dsl

        attr_accessor :skip_file

        def initialize(backend, conf, dependencies, require_loader, skip_only_if_eval)
          @backend = backend
          @conf = conf
          @dependencies = dependencies
          @require_loader = require_loader
          @skip_file_message = nil
          @skip_file = false
          @skip_only_if_eval = skip_only_if_eval
        end

        define_method :title do |arg|
          profile_context_owner.set_header(:title, arg)
        end

        def to_s
          "Control Evaluation Context (#{profile_name})"
        end

        define_method :profile_name do
          profile_id
        end

        define_method :control do |*args, &block|
          id = args[0]
          opts = args[1] || {}
          opts[:skip_only_if_eval] = @skip_only_if_eval
          register_control(rule_class.new(id, profile_id, opts, &block))
        end

        #
        # Describe allows users to write rspec-like bare describe
        # blocks without declaring an inclosing control. Here, we
        # generate a control for them automatically and then execute
        # the describe block in the context of that control.
        #
        define_method :describe do |*args, &block|
          loc = block_location(block, caller(1..1).first)
          id = "(generated from #{loc} #{SecureRandom.hex})"

          res = nil
          rule = rule_class.new(id, profile_id, {}) do
            res = describe(*args, &block)
          end
          register_control(rule, &block)

          res
        end

        define_method :add_resource do |name, new_res|
          resources_dsl.module_exec do
            define_method name.to_sym do |*args|
              new_res.new(@backend, name.to_s, *args)
            end
          end
        end

        define_method :add_resources do |context|
          self.class.class_eval do
            include context.to_resources_dsl
          end

          rule_class.class_eval do
            include context.to_resources_dsl
          end
        end

        define_method :add_subcontext do |context|
          profile_context_owner.add_subcontext(context)
        end

        define_method :register_control do |control, &block|
          if @skip_file
            ::Inspec::Rule.set_skip_rule(control, true, @skip_file_message)
          end

          unless profile_context_owner.profile_supports_platform?
            platform = inspec.platform
            msg = "Profile #{profile_context_owner.profile_id} is not supported on platform #{platform.name}/#{platform.release}."
            ::Inspec::Rule.set_skip_rule(control, true, msg)
          end

          unless profile_context_owner.profile_supports_inspec_version?
            msg = "Profile #{profile_context_owner.profile_id} is not supported on InSpec version (#{Inspec::VERSION})."
            ::Inspec::Rule.set_skip_rule(control, true, msg)
          end

          profile_context_owner.register_rule(control, &block) unless control.nil?
        end

        # method for attributes; import attribute handling
        define_method :attribute do |name, options = nil|
          if options.nil?
            Inspec::AttributeRegistry.find_attribute(name, profile_id).value
          else
            profile_context_owner.register_attribute(name, options)
          end
        end

        define_method :skip_control do |id|
          profile_context_owner.unregister_rule(id)
        end

        define_method :only_if do |message = nil, &block|
          return unless block
          return if @skip_file == true
          return if @skip_only_if_eval == true

          return if block.yield == true
          # Apply `set_skip_rule` for other rules in the same file
          profile_context_owner.rules.values.each do |r|
            sources_match = r.source_file == block.source_location[0]
            Inspec::Rule.set_skip_rule(r, true, message) if sources_match
          end

          @skip_file_message = message
          @skip_file = true
        end

        alias_method :rule, :control
        alias_method :skip_rule, :skip_control

        private

        def block_location(block, alternate_caller)
          if block.nil?
            alternate_caller[/^(.+:\d+):in .+$/, 1] || 'unknown'
          else
            path, line = block.source_location
            "#{File.basename(path)}:#{line}"
          end
        end
      end
    end
  end
end
