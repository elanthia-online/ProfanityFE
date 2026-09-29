#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks that the YARD tags in the documented sources match the code.
#
# `yard doc --fail-on-warning` catches malformed tags and `yard stats
# --list-undoc` catches objects with no docstring, but neither checks that
# a method's tags describe its signature and body. This script reports, for
# every method (private ones included) in the files listed in .yardopts:
#
# - a missing docstring, or one that is only a section banner
#   ("# ---- Helpers ----", which YARD attaches to the next object);
# - a parameter with no @param tag (a &block parameter may be documented
#   with @yield/@yieldparam instead);
# - a @param tag naming a parameter the method doesn't have;
# - a missing @return tag (except on #initialize);
# - a body that yields (yield or block_given?) with no @yield/@yieldparam;
# - a body that calls raise/fail with no @raise;
# - a @param/@return/@raise tag with no type;
# - an attribute with only the placeholder docstring YARD writes
#   ("Returns the value of attribute x.").
#
# It also reports method-only tags (@param, @return, @yield, @raise, ...)
# and section banners on constants, classes and modules.
#
# Only the tags written in the comment count, not those YARD infers. The
# body checks skip nested def/class/module bodies. A yield in a lambda or
# in a block that runs later or on another thread (given to proc, lambda,
# on, at_exit, trap, define_method, Thread.new/start) still counts, since
# it calls the method's block; a raise there doesn't, and neither does a
# raise that a rescue around it in the same method catches.
#
# Each gap is printed as "file:line Path: gap"; the exit status is 1 when
# there is at least one gap.
#
# Usage:
#   ruby script/check_yard_tags.rb             # files listed in .yardopts
#   ruby script/check_yard_tags.rb FILE...     # the given files
#   ruby script/check_yard_tags.rb --self-test # check the checker

require 'prism'
require 'tmpdir'
require 'yard'

# See the file header.
module YardTagCheck
  # One reported gap.
  Gap = Struct.new(:file, :line, :path, :message) do
    def to_s
      "#{file}:#{line} #{path}: #{message}"
    end
  end

  # Tags that only mean something on a method.
  METHOD_ONLY_TAGS = %i[param option return yield yieldparam yieldreturn raise].freeze

  # Tags that must carry a type.
  TYPED_TAGS = %i[param return raise].freeze

  module_function

  # The source globs listed in .yardopts (every line that isn't an option).
  def yardopts_files(root = Dir.pwd)
    File.readlines(File.join(root, '.yardopts'), chomp: true)
        .map(&:strip)
        .reject { |line| line.empty? || line.start_with?('-') }
        .flat_map { |glob| Dir.glob(File.join(root, glob)) }
        .map { |path| path.delete_prefix("#{root}/") }
        .uniq.sort
  end

  # Parse the files and return every gap, ordered by file and line.
  def check(files)
    YARD::Registry.clear
    YARD.parse(files)
    defs = files.to_h { |file| [file, def_nodes(file)] }
    gaps = YARD::Registry.all.flat_map do |object|
      next [] unless files.include?(object.file)

      if object.type == :method
        method_gaps(object, defs[object.file][object.line])
      else
        misplaced_tag_gaps(object)
      end
    end
    # module_function copies each method to a private instance method:
    # report the pair once.
    gaps.uniq { |gap| [gap.file, gap.line, gap.path.sub(/\A.*[#.]/, ''), gap.message] }
        .sort_by { |gap| [gap.file, gap.line, gap.path, gap.message] }
  end

  # Map each def's first line to its node.
  def def_nodes(file)
    nodes = {}
    stack = [Prism.parse_file(file).value]
    until stack.empty?
      node = stack.pop
      nodes[node.location.start_line] = node if node.is_a?(Prism::DefNode)
      stack.concat(node.compact_child_nodes)
    end
    nodes
  end

  # The tags written in the object's comment. YARD adds tags of its own
  # while parsing (@raise for each `raise Class`, @yield for each `yield`,
  # @return [Boolean] on a method ending in ?), so object.tags would hide
  # exactly the gaps this script looks for.
  def written_tags(object)
    YARD::Docstring.new(object.docstring.all).tags
  end

  # Gaps on one method.
  def method_gaps(object, def_node)
    tags = written_tags(object).group_by { |tag| tag.tag_name.to_sym }
    tags.default = []
    gap = ->(message) { Gap.new(object.file, object.line, object.path, message) }
    return attribute_gaps(object, tags).map(&gap) if object.is_attribute?

    gaps = []
    gaps << gap.call('no docstring') if object.docstring.all.strip.empty?
    gaps << gap.call(BANNER_GAP) if banner?(object)
    gaps.concat(param_gaps(object, tags).map(&gap))
    gaps << gap.call('missing @return') if tags[:return].empty? && object.name != :initialize
    gaps.concat(untyped_tag_gaps(tags).map(&gap))
    return gaps unless def_node

    body = body_calls(def_node.body)
    if body[:yields] && tags[:yield].empty? && tags[:yieldparam].empty?
      gaps << gap.call('yields but has no @yield or @yieldparam')
    end
    gaps << gap.call('calls raise but has no @raise') if body[:raises] && tags[:raise].empty?
    gaps
  end

  # Gaps on an attribute: YARD's placeholder text ("Returns the value of
  # attribute x.") where a docstring should be, or an untyped tag.
  def attribute_gaps(object, tags)
    gaps = untyped_tag_gaps(tags).reject { |message| object.writer? && message.start_with?('@param value ') }
    return gaps unless object.docstring.all.strip.empty? || object.docstring.all.match?(ATTRIBUTE_PLACEHOLDER)

    gaps << 'attribute has only the placeholder docstring YARD writes'
  end

  # The start of the docstring YARD writes for an undocumented attribute.
  ATTRIBUTE_PLACEHOLDER = /\A(Returns the value of attribute|Sets the attribute) /

  # Missing and stale @param tags.
  def param_gaps(object, tags)
    block_documented = tags[:yield].any? || tags[:yieldparam].any?
    names = []
    gaps = []
    object.parameters.each do |raw, _default|
      name = raw.to_s.sub(/\A[*&]+/, '').delete_suffix(':')
      next if name.empty? || name == '...'

      names << name
      next if tags[:param].any? { |tag| tag.name == name }
      next if raw.to_s.start_with?('&') && block_documented

      gaps << "missing @param #{name}"
    end
    tags[:param].each do |tag|
      gaps << "stale @param #{tag.name}" unless names.include?(tag.name)
    end
    gaps
  end

  # @param/@return/@raise tags written without a [Type].
  def untyped_tag_gaps(tags)
    TYPED_TAGS.flat_map { |name| tags[name] }
              .select { |tag| tag.types.nil? || tag.types.empty? }
              .map { |tag| "@#{tag.tag_name} #{tag.name} has no type".squeeze(' ') }
  end

  # Method-only tags on a constant, class or module, and a section banner
  # taken as the docstring.
  def misplaced_tag_gaps(object)
    messages = written_tags(object).select { |tag| METHOD_ONLY_TAGS.include?(tag.tag_name.to_sym) }
                                   .map { |tag| "@#{tag.tag_name} on a #{object.type} (YARD ignores it)" }
    messages << BANNER_GAP if banner?(object)
    messages.map { |message| Gap.new(object.file, object.line, object.path, message) }
  end

  # Reported when the only comment above an object is a section banner.
  BANNER_GAP = 'docstring is only a section banner'

  # Whether the object's whole docstring is a banner such as
  # "---- Helpers ----", which YARD attaches to the next object.
  def banner?(object)
    object.docstring.all.strip.match?(/\A(-{3,}|={3,})[^\n]*\1\z/)
  end

  # Whether a method body yields or raises. Nested def/class/module bodies
  # are skipped: a yield or raise there belongs to that other method. A
  # lambda, or a block given to {DEFERRING_CALLS} or Thread.new/start, runs
  # later or on another thread: a yield there still calls this method's
  # block, so it counts, but a raise there doesn't leave this method, so it
  # doesn't. Nor does a raise that a surrounding rescue in the method
  # catches.
  def body_calls(body)
    found = { yields: false, raises: false }
    stack = [[body, [], false]]
    until stack.empty?
      node, rescued, deferred = stack.pop
      next if node.nil?

      case node
      when Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode
        next
      when Prism::LambdaNode
        deferred = true
      when Prism::YieldNode
        found[:yields] = true
      when Prism::BeginNode
        caught = rescued + rescued_classes(node.rescue_clause)
        stack << [node.statements, caught, deferred]
        stack.concat([node.rescue_clause, node.else_clause, node.ensure_clause].map { |child| [child, rescued, deferred] })
        next
      when Prism::RescueModifierNode
        stack << [node.expression, rescued + ['StandardError'], deferred] << [node.rescue_expression, rescued, deferred]
        next
      when Prism::CallNode
        if node.receiver.nil?
          found[:yields] = true if node.name == :block_given?
          if %i[raise fail].include?(node.name) && !deferred && !caught?(raised_class(node), rescued)
            found[:raises] = true
          end
        end
        if deferred_block?(node)
          stack.concat([node.receiver, node.arguments].map { |child| [child, rescued, deferred] })
          stack << [node.block, rescued, true]
          next
        end
      end
      stack.concat(node.compact_child_nodes.map { |child| [child, rescued, deferred] })
    end
    found
  end

  # The class names a chain of rescue clauses catches (a bare rescue
  # catches StandardError).
  def rescued_classes(clause)
    names = []
    while clause
      names.concat(clause.exceptions.empty? ? ['StandardError'] : clause.exceptions.map(&:slice))
      clause = clause.subsequent
    end
    names
  end

  # The class a raise/fail call raises: its first argument when that is a
  # constant, RuntimeError for a message only, nil (unknown) otherwise.
  # A bare raise re-raises the exception being handled: nil too.
  def raised_class(call)
    first = call.arguments&.arguments&.first
    case first
    when Prism::ConstantReadNode, Prism::ConstantPathNode then first.slice
    when Prism::StringNode, Prism::InterpolatedStringNode then 'RuntimeError'
    end
  end

  # Whether an exception of the named class is caught by one of the
  # rescued class names. Classes this script can load are compared by
  # ancestry (IOError is caught by StandardError); others by name.
  def caught?(raised, rescued)
    return false if raised.nil?

    raised_class = resolve_class(raised)
    rescued.any? do |name|
      rescuer = resolve_class(name)
      name == raised || (raised_class && rescuer && raised_class <= rescuer)
    end
  end

  # The exception class of that name, if this process has it.
  def resolve_class(name)
    klass = Object.const_get(name)
    klass if klass.is_a?(Class) && klass <= Exception
  rescue NameError
    nil
  end

  # Calls whose block is stored to run later, not run by the call.
  DEFERRING_CALLS = %i[proc lambda on at_exit trap define_method].freeze

  # Whether the call's block runs later or on another thread.
  def deferred_block?(call)
    return false unless call.block.is_a?(Prism::BlockNode)
    return true if DEFERRING_CALLS.include?(call.name)

    %i[new start].include?(call.name) && call.receiver.is_a?(Prism::ConstantReadNode) && call.receiver.name == :Thread
  end

  # Print the gaps and return the exit status.
  def run(files, out: $stdout)
    gaps = check(files)
    gaps.each { |gap| out.puts gap }
    out.puts "#{gaps.size} YARD tag gap(s) in #{files.size} file(s)."
    gaps.empty? ? 0 : 1
  end

  # Source for the self-test: one method per gap kind, plus methods that
  # must produce no gap. {SELF_TEST_EXPECTED} lists the gaps.
  SELF_TEST_SOURCE = <<~RUBY
    # Fixture.
    module Fixture
      # Tagged on a constant.
      # @return [Integer] ignored by YARD
      LIMIT = 3

      # No @param for b.
      # @param a [Integer] first
      # @return [Integer]
      def self.missing_param(a, b) = a + b

      # Names a parameter that is gone.
      # @param a [Integer] first
      # @param gone [Integer] removed
      # @return [Integer]
      def self.stale_param(a) = a

      # No @return.
      # @param a [Integer] first
      def self.missing_return(a) = a

      # No @return on a predicate (YARD would add @return [Boolean]).
      def self.missing_predicate_return? = nil

      # Yields without @yield.
      # @return [void]
      def self.undocumented_yield
        yield 1
      end

      # Yields, on another thread, without @yield.
      # @return [Thread]
      def self.undocumented_yield_in_thread
        Thread.new { yield 1 }
      end

      # Yields, from a lambda, without @yield.
      # @return [Integer]
      def self.undocumented_yield_in_lambda = -> { yield 1 }.call

      # Tests block_given? without @yield.
      # @return [Boolean]
      def self.undocumented_block_given = block_given?

      # Raises without @raise.
      # @param a [Integer] first
      # @return [Integer]
      def self.undocumented_raise(a)
        raise ArgumentError, 'negative' if a.negative?

        a
      end

      # Re-raises without @raise.
      # @return [void]
      def self.undocumented_reraise
        Integer('x')
      rescue ArgumentError
        raise
      end

      # Untyped tags.
      # @param a first
      # @return the value
      def self.untyped(a) = a

      def self.undocumented = nil

      # ---- Banner ----
      def self.banner_only = nil

      attr_reader :placeholder, :documented, :untyped_attribute
      # @!attribute [r] documented
      #   @return [Integer] documented after the attr_reader
      # @!attribute [r] untyped_attribute
      #   @return an untyped attribute

      # Clean: a documented accessor.
      # @return [String]
      attr_accessor :documented_accessor

      # ---- Banner ----
      BANNER_CONSTANT = 1

      # Clean: keyword, splat and block parameters, with @yield for the block.
      # @param a [Integer] first
      # @param rest [Array<Integer>] others
      # @param key [Symbol] a keyword
      # @param opts [Hash] other keywords
      # @yield [Integer] each value
      # @return [void]
      def self.clean_params(a, *rest, key: :x, **opts, &block)
        [a, *rest].each(&block)
      end

      # Clean: a stored block documented as a @param.
      # @param handler [Proc] called later
      # @return [Proc]
      def self.clean_block_param(&handler) = handler

      # Clean: the words raise and yield in strings and comments, and a raise
      # inside a nested def.
      # @return [String]
      def self.clean_words
        # raise yield

        # Nested helper.
        # @raise [RuntimeError] always
        # @return [void]
        def helper = raise('only in the nested def')
        'raise yield'
      end

      # Clean: raises only in code that runs later or on another thread.
      # @param parser [OptionParser] the parser to add an option to
      # @return [Array] the stored code
      def self.clean_deferred_raise(parser)
        parser.on('--x=N') { |v| raise ArgumentError, v }
        [Thread.new { raise 'in a thread' }, -> { raise 'later' }, proc { fail 'later' }]
      end

      # Raises inside a block the call runs now.
      # @param values [Array<Integer>] the values
      # @return [void]
      def self.undocumented_raise_in_block(values)
        values.each { |v| raise ArgumentError, 'negative' if v.negative? }
      end

      # Clean: raises only exceptions it rescues itself.
      # @return [Integer, nil]
      def self.clean_rescued_raise
        begin
          raise IOError, 'failed'
        rescue SystemCallError, IOError
          nil
        end
        begin
          raise ArgumentError, 'caught by the bare rescue'
        rescue
          nil
        end
        (raise 'caught by the modifier' rescue nil)
        Integer('1')
      rescue ArgumentError
        nil
      end

      # Raises what its rescue doesn't catch.
      # @return [void]
      def self.undocumented_uncaught_raise
        raise IOError, 'not an ArgumentError'
      rescue ArgumentError
        nil
      end

      # Clean: yields and raises, both documented.
      # @yieldparam value [Integer] the value
      # @raise [ArgumentError] when there is no block
      # @return [void]
      def self.clean_yield_raise
        raise ArgumentError, 'no block' unless block_given?

        yield 1
      end

      # Clean: #initialize needs no @return.
      # @param a [Integer] first
      def initialize(a)
        @a = a
      end
    end
  RUBY

  # The gaps the checker must report for {SELF_TEST_SOURCE}, by object path.
  SELF_TEST_EXPECTED = {
    'Fixture::LIMIT'                       => ['@return on a constant (YARD ignores it)'],
    'Fixture.missing_param'                => ['missing @param b'],
    'Fixture.stale_param'                  => ['stale @param gone'],
    'Fixture.missing_return'               => ['missing @return'],
    'Fixture.missing_predicate_return?'    => ['missing @return'],
    'Fixture.undocumented_yield'           => ['yields but has no @yield or @yieldparam'],
    'Fixture.undocumented_yield_in_thread' => ['yields but has no @yield or @yieldparam'],
    'Fixture.undocumented_yield_in_lambda' => ['yields but has no @yield or @yieldparam'],
    'Fixture.undocumented_block_given'     => ['yields but has no @yield or @yieldparam'],
    'Fixture.undocumented_raise'           => ['calls raise but has no @raise'],
    'Fixture.undocumented_reraise'         => ['calls raise but has no @raise'],
    'Fixture.undocumented_raise_in_block'  => ['calls raise but has no @raise'],
    'Fixture.undocumented_uncaught_raise'  => ['calls raise but has no @raise'],
    'Fixture.untyped'                      => ['@param a has no type', '@return has no type'],
    'Fixture.undocumented'                 => ['no docstring', 'missing @return'],
    'Fixture.banner_only'                  => ['docstring is only a section banner', 'missing @return'],
    'Fixture::BANNER_CONSTANT'             => ['docstring is only a section banner'],
    'Fixture#placeholder'                  => ['attribute has only the placeholder docstring YARD writes'],
    'Fixture#untyped_attribute'            => ['@return has no type']
  }.freeze

  # Check the checker against {SELF_TEST_SOURCE}: it must report exactly
  # {SELF_TEST_EXPECTED}.
  def self_test(out: $stdout)
    Dir.mktmpdir do |dir|
      file = File.join(dir, 'fixture.rb')
      File.write(file, SELF_TEST_SOURCE)
      expected = SELF_TEST_EXPECTED.flat_map { |path, messages| messages.map { |message| [path, message] } }
      actual = check([file]).map { |gap| [gap.path, gap.message] }
      (expected - actual).each { |path, message| out.puts "self-test: not reported: #{path}: #{message}" }
      (actual - expected).each { |path, message| out.puts "self-test: false positive: #{path}: #{message}" }
      ok = expected.sort == actual.sort
      out.puts "self-test: #{ok ? 'ok' : 'FAILED'} (#{expected.size} expected gaps)"
      ok ? 0 : 1
    end
  end
end

if $PROGRAM_NAME == __FILE__
  log.level = YARD::Logger::ERROR
  if ARGV == ['--self-test']
    exit YardTagCheck.self_test
  else
    exit YardTagCheck.run(ARGV.empty? ? YardTagCheck.yardopts_files : ARGV)
  end
end
