# frozen_string_literal: true

require 'slop'
require 'sym'
require 'colored2'
require 'yaml'
require 'openssl'
require 'highline'
require 'forwardable'

require 'sym/application'
require 'sym/errors'

require 'sym/app/commands'
require 'sym/app/keychain'
require 'sym/app/private_key/handler'

require 'sym/app/output/base'
require 'sym/app/output/file'
require 'sym/app/output/stdout'
require 'sym/app/cli_slop'

module Sym
  module App
    # This is the main interface class for the CLI application.
    # It is responsible for parsing user's input, providing help, examples,
    # coordination of various sub-systems (such as PrivateKey detection), etc.
    #
    # Besides holding the majority of the application state, it contains
    # two primary public methods: +#new+ and +#run+.
    #
    # The constructor is responsible for parsing the flags and determining
    # the the application is about to do. It sets up input/output, but doesn't
    # really execute any encryption or decryption. This happens in the +#run+
    # method called immediately after +#new+.
    #
    # {{Shh::App::CLI}} module effectively performs the translation of
    # the +opts+ object (of type {Slop::Result}) and interpretation of
    # users intentions. It holds on to +opts+ for the duration of the program.
    #
    # == Responsibility Delegated
    #
    # The responsibility of determining the private key from various
    # options provided is performed by the {Sym::App::PrivateKey::Handler}
    # instance. See there for more details.
    #
    # Subsequently, +#run+ method handles the finding of the appropriate
    # {Sym::App::Commands::BaseCommand} subclass to respond to user's request.
    # Command registry, sorting, command dependencies, and finding them is
    # done by the {Sym::App::Coommands} module.
    #
    # User input is handled by the {Sym::App::Input::Handler} instance, while
    # the output is provided by the procs in the {Sym::App::Output} classes.
    #
    # Finally, the Mac OS-X -specific usage of the KeyChain, is encapsulated
    # in a cross-platform way inside the {Sym::App::Keychain} module.

    class CLI
      # brings in #parse(Array[String] args)
      include CLISlop

      attr_accessor :opts, :application, :outputs, :stdin, :stdout, :stderr, :kernel, :argv
      attr_accessor :env_args

      extend Forwardable

      def_delegators :@application, :command

      def initialize(cli_argv = ARGV.dup, stdin = STDIN, stdout = STDOUT, stderr = STDERR, kernel = nil)
        self.stdin  = stdin
        self.stdout = stdout
        self.stderr = stderr
        self.kernel = kernel
        self.argv   = cli_argv

        Sym::App.stdin  = stdin
        Sym::App.stdout = stdout
        Sym::App.stderr = stderr

        self.env_args = nil

        begin
          # Re-map any legacy options to the new options
          self.opts = parse(argv).to_hash

          if opts[:sym_args]
            self.argv = normalize_env_args
            self.opts = parse(argv).to_hash
          end

          # Disable coloring if requested, or if piping STDOUT
          if opts[:no_color] || !self.stdout.tty?
            Colored2.disable! # reparse options without the colors to create new help msg
            self.opts = parse(argv).to_hash
          end
        rescue StandardError => e
          log :error, e.message.to_s if opts
          error exception: e
          exit_program!
        end

        self.opts = opts_present(opts)
        self.application = ::Sym::Application.new(opts, stdin, stdout, stderr, kernel, argv)
      end

      def exit_program!
        exit 123 if stdin == STDIN
      end

      def normalize_env_args
        self.env_args = (fetch_env_args || '').split(' ').compact
        return argv if env_args.nil? || env_args.empty?

        puts env_args.inspect.bold.yellow
        (argv + env_args).flatten.uniq
      end

      def fetch_env_args
        ENV[Sym::Constants::ENV_ARGS_VARIABLE_NAME]
      end

      def execute!
        execute
      end

      def output_proc(proc = nil)
        if application
          application.output = proc if proc
          application.output
        end
      end

      def execute
        return Sym::App.exit_code if Sym::App.exit_code != 0

        result = application.execute
        if result.is_a?(Hash)
          output_proc ::Sym::App::Args.new({}).output_class
          error(result)
        end
        Sym::App.exit_code
      end

      def opts_present(hash = opts)
        o = hash.dup
        o.keys.map { |k| o[k] ? nil : k }.compact.each { |k| o.delete(k) }
        o
      end

      private

      def log(*args)
        Sym::App.log(*args, **opts.to_hash)
      end

      def error(hash)
        hash.merge!(config: opts.to_hash) if opts
        hash.merge!(command: @command) if @command
        Sym::App.error(**hash)
      end
    end
  end
end
