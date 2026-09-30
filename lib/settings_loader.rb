# frozen_string_literal: true

# Parses .profanity.xml settings and populates global constants
# (HIGHLIGHT, PRESET, LAYOUT, PERC_TRANSFORMS) and gag patterns.

require 'digest'

# Lightweight stand-in for REXML::Element that can be Marshal'd.
# Supports the same interface used by SettingsLoader and WindowManager:
# .name, .attributes[], .text, and .elements.each.
class CachedElement
  attr_reader :name, :attributes, :text, :children

  # @!attribute [r] name
  #   @return [String] the element's tag name
  # @!attribute [r] attributes
  #   @return [Hash{String => String}] the element's attributes by name
  # @!attribute [r] text
  #   @return [String, nil] the element's first text node, as
  #     REXML::Element#text gives it; nil when it has none
  # @!attribute [r] children
  #   @return [Array<CachedElement>] the child elements, in document order

  # @param name [String] the element's tag name
  # @param attributes [Hash{String => String}] the element's attributes
  # @param text [String, nil] the element's first text node
  # @param children [Array<CachedElement>] the child elements
  def initialize(name, attributes, text, children)
    @name = name
    @attributes = attributes
    @text = text
    @children = children
  end

  # Child elements, mirroring REXML::Element#elements.
  #
  # @return [Array<CachedElement>] the children
  def elements
    @children
  end
end

# Parses a .profanity.xml configuration file and populates global constants.
#
# On initial load, populates PRESET (color presets), LAYOUT (window layouts),
# HIGHLIGHT (regex-based text highlighting), PERC_TRANSFORMS (percWindow text
# substitutions), gag patterns (via GagPatterns), and key bindings.
# On reload, only refreshes HIGHLIGHT, gag patterns, perc-transforms, the
# notification stream, the history size, and key bindings -- PRESET and
# LAYOUT are preserved.
#
# The file is parsed in full before anything is applied, so a file that
# fails to load changes nothing. The new settings are then applied together
# under SETTINGS_LOCK to prevent races with the server read thread.
#
# @example
#   SettingsLoader.load('char.profanity.xml', key_binding, key_action, do_macro)
#   SettingsLoader.load('char.profanity.xml', key_binding, key_action, do_macro, reload: true)
module SettingsLoader
  module_function

  # Version of the on-disk settings cache layout. Bump it when CachedElement
  # or the cache payload changes so existing caches are rebuilt.
  CACHE_FORMAT_VERSION = 1

  # Load or reload settings from an XML configuration file.
  #
  # Parses the XML and populates global constants. On initial load
  # (+reload: false+), processes all element types including +preset+
  # and +layout+. On reload (+reload: true+), skips presets and layouts
  # and only refreshes highlights, gag patterns, perc-transforms, the
  # notification stream, the history size, and key bindings.
  #
  # The whole file is parsed before anything is applied, so a file that
  # fails to load (malformed XML, or any other error that aborts the parse)
  # changes nothing. A single invalid entry, such as a bad highlight regex,
  # is warned about and skipped without failing the file.
  #
  # +key_binding+ is cleared and rebuilt from the file on every successful
  # load, so bindings changed at runtime (e.g. by switch_arrow_mode) revert
  # to the file's.
  #
  # @param filename [String] path to the .profanity.xml configuration file
  # @param key_binding [Hash] mutable hash of key bindings, replaced in place
  # @param key_action [Hash<String, Proc>] named action procs available for key binding
  # @param do_macro [#call] runs a macro; called with the macro string
  #   (Application passes its +do_macro+ Method)
  # @param reload [Boolean] when true, skip PRESET/LAYOUT population and only refresh dynamic settings
  # @param keep_highlights [Hash{Regexp => Array}] highlights to keep on top
  #   of the file's (e.g. those added with +.highlight+), applied in the same
  #   locked step so HIGHLIGHT is never without them
  # @return [StandardError, nil] nil when the settings were applied, otherwise
  #   the error that stopped the load (logged with its backtrace); no setting
  #   was changed
  def load(filename, key_binding, key_action, do_macro, reload: false, keep_highlights: {})
    unless File.exist?(filename)
      warn "Settings file not found: #{filename}"
      return Errno::ENOENT.new(filename)
    end

    settings = parse(load_cached_xml(filename), key_action, do_macro, reload: reload)
    apply(settings, key_binding, reload: reload, keep_highlights: keep_highlights)
    nil
  rescue StandardError => e
    ProfanityLog.write('settings', e.message, backtrace: e.backtrace)
    e
  end

  # Build the settings described by a parsed settings tree without touching
  # any global state.
  #
  # @param xml_root [CachedElement] root element of the parsed settings
  # @param key_action [Hash<String, Proc>] named action procs available for key binding
  # @param do_macro [#call] runs a macro; called with the macro string
  # @param reload [Boolean] when true, presets and layouts are not collected
  # @return [Hash] the settings, for {apply}: +:highlight+, +:perc_transforms+,
  #   +:notification_stream+, +:history_size+, +:gags+ (keyword arguments for
  #   GagPatterns.replace_custom), +:key_binding+, +:presets+ and +:layouts+
  # @api private
  def parse(xml_root, key_action, do_macro, reload: false)
    setup_key = build_setup_key(key_action, do_macro)
    # Key bindings start from an empty hash so a key whose kind changed
    # (action vs combo) isn't reported as conflicting with the previous load.
    settings = {
      highlight: {}, perc_transforms: [], notification_stream: Config::DEFAULT_NOTIFICATION_STREAM,
      history_size: Config::DEFAULT_HISTORY_SIZE,
      gags: { general: [], multiline: [], combat: [] }, key_binding: {}, presets: {}, layouts: {}
    }

    xml_root.elements.each do |e|
      case e.name
      when 'highlight'
        begin
          pattern = e.text&.strip
          r = pattern && !pattern.empty? ? Regexp.new(pattern) : nil
        rescue StandardError => e_err
          r = nil
          warn e
          warn e_err
        end
        settings[:highlight][r] = [e.attributes['fg'], e.attributes['bg'], e.attributes['ul']] if r

      when 'key'
        setup_key.call(e, settings[:key_binding])

      when 'gag'
        settings[:gags][:general] << e.text if e.text && !e.text.strip.empty?

      when 'combat_gag'
        settings[:gags][:combat] << e.text if e.text && !e.text.strip.empty?

      when 'multiline_gag'
        start_pattern = e.attributes['start']
        if start_pattern && !start_pattern.strip.empty?
          settings[:gags][:multiline] << { start: start_pattern, end: e.attributes['end'] }
        end

      when 'notification-stream'
        settings[:notification_stream] = e.text.strip if e.text && !e.text.strip.empty?

      when 'history-size'
        size = e.text&.strip
        if size&.match?(/\A\d+\z/)
          settings[:history_size] = size.to_i
        else
          ProfanityLog.write('settings', "Invalid history-size '#{size}' (expected a whole number), using #{settings[:history_size]}")
        end

      when 'perc-transform'
        if e.attributes['pattern']
          begin
            pattern = Regexp.new(e.attributes['pattern'])
            replacement = e.attributes['replace'] || ''
            settings[:perc_transforms].push([pattern, replacement])
          rescue RegexpError => e_err
            warn "Invalid perc-transform pattern: #{e.attributes['pattern']} - #{e_err}"
          end
        end
      end

      # Presets and layouts are only loaded on initial load, not reload
      next if reload

      case e.name
      when 'preset'
        settings[:presets][e.attributes['id']] = [e.attributes['fg'], e.attributes['bg']]
      when 'layout'
        settings[:layouts][e.attributes['id']] = e if e.attributes['id']
      end
    end

    settings
  end

  # Apply settings built by {parse} to the global state, all under
  # SETTINGS_LOCK so the server thread never sees a mix of old and new.
  #
  # Highlights, perc-transforms, custom gags and key bindings are replaced,
  # so an entry removed from the file doesn't linger. The notification
  # stream and history size fall back to their defaults when the file
  # doesn't set them. Presets and layouts are added on initial load only.
  #
  # +keep_highlights+ are merged over the file's highlights in the same
  # step, after them and winning for the same regex, as if they had been
  # added to the new highlights one by one.
  #
  # @param settings [Hash] settings returned by {parse}
  # @param key_binding [Hash] mutable hash of key bindings, replaced in place
  # @param reload [Boolean] when true, presets and layouts are left as they are
  # @param keep_highlights [Hash{Regexp => Array}] highlights to keep on top of the file's
  # @return [void]
  # @api private
  def apply(settings, key_binding, reload: false, keep_highlights: {})
    SETTINGS_LOCK.synchronize do
      # Gags go first: compiling them is the only step here that could
      # raise, and GagPatterns replaces nothing until all have compiled.
      GagPatterns.replace_custom(**settings[:gags])
      HIGHLIGHT.replace(settings[:highlight].merge(keep_highlights))
      PERC_TRANSFORMS.replace(settings[:perc_transforms])
      CONFIG.notification_stream = settings[:notification_stream]
      CONFIG.history_size = settings[:history_size]
      key_binding.replace(settings[:key_binding])
      next if reload

      PRESET.merge!(settings[:presets])
      LAYOUT.merge!(settings[:layouts])
    end
  end

  # Load the XML settings, using a Marshal cache when possible.
  #
  # The cache records a digest of the XML it was built from and is used only
  # while that digest matches the file's current content, in which case the
  # cached CachedElement tree is returned without parsing (~1ms). Comparing
  # modification times is not enough: a file rewritten within the same
  # filesystem clock tick as the cache keeps an equal mtime. Otherwise the XML
  # is parsed with REXML, converted to CachedElements, and cached for next time.
  #
  # @param filename [String] path to the .profanity.xml file
  # @return [CachedElement] root element of the parsed settings
  # @raise [REXML::ParseException] if the XML is malformed or the file is empty
  def load_cached_xml(filename)
    # Settings files are UTF-8 (the bundled templates contain em-dashes);
    # don't depend on the locale's default encoding, which is US-ASCII under C/POSIX.
    xml_string = File.read(filename, encoding: Encoding::UTF_8)
    digest = Digest::SHA256.hexdigest(xml_string)
    cache_file = cache_path_for(filename)

    cached_root = read_cache(cache_file, digest)
    return cached_root if cached_root

    xml_doc = REXML::Document.new(sanitize_xml_comments(xml_string))
    # REXML reports "No root element" for a file of only whitespace or
    # comments, but parses an empty one to a document with no root.
    raise REXML::ParseException, "Settings file is empty: #{filename}" unless xml_doc.root

    cached_root = rexml_to_cached(xml_doc.root)
    write_cache(cache_file, digest, cached_root)
    cached_root
  end

  # Read a cached settings tree if it was built from XML with the given digest.
  #
  # @param cache_file [String, nil] cache path, or nil when caching is unavailable
  # @param digest [String] SHA-256 hex digest of the current XML content
  # @return [CachedElement, nil] the cached tree, or nil if missing, stale, or unreadable
  # @api private
  def read_cache(cache_file, digest)
    return nil unless cache_file && File.exist?(cache_file)

    payload = Marshal.load(File.binread(cache_file))
    return nil unless payload.is_a?(Hash) && payload[:version] == CACHE_FORMAT_VERSION && payload[:digest] == digest

    payload[:root]
  rescue StandardError
    nil # Cache corrupt or incompatible -- caller falls back to a full parse
  end

  # Write a settings tree to the cache along with the digest of its source XML.
  #
  # @param cache_file [String, nil] cache path, or nil when caching is unavailable
  # @param digest [String] SHA-256 hex digest of the XML the tree was built from
  # @param cached_root [CachedElement] root element to cache
  # @return [void]
  # @api private
  def write_cache(cache_file, digest, cached_root)
    return unless cache_file

    File.binwrite(cache_file, Marshal.dump({ version: CACHE_FORMAT_VERSION, digest: digest, root: cached_root }))
  rescue StandardError => e
    ProfanityLog.write('settings', "Failed to write settings cache: #{e.message}")
  end

  # Convert an REXML::Element tree to a CachedElement tree.
  #
  # @param element [REXML::Element] source element
  # @return [CachedElement] lightweight equivalent
  def rexml_to_cached(element)
    attrs = {}
    element.attributes.each { |k, v| attrs[k] = v }
    children = element.elements.map { |child| rexml_to_cached(child) }
    CachedElement.new(element.name, attrs, element.text, children)
  end

  # Compute the cache file path for a given XML settings file.
  # Cache lives in ~/.profanity/ alongside log files. The name includes a
  # digest of the file's full path so settings files that share a basename
  # in different directories get separate caches.
  #
  # @param filename [String] path to the XML file
  # @return [String, nil] cache path, or nil if APP_DIR is unavailable
  def cache_path_for(filename)
    dir = defined?(ProfanitySettings::APP_DIR) ? ProfanitySettings::APP_DIR : nil
    return nil unless dir

    basename = File.basename(filename, File.extname(filename))
    path_digest = Digest::SHA256.hexdigest(File.expand_path(filename))[0, 12]
    File.join(dir, "#{basename}-#{path_digest}.settings.cache")
  end

  # Replace '--' inside XML comments with '~~' to avoid REXML parse errors.
  # The XML spec forbids '--' inside comments; older templates may contain it.
  #
  # @param xml_string [String] raw XML content
  # @return [String] sanitized XML content
  # @api private
  def sanitize_xml_comments(xml_string)
    xml_string.gsub(/<!--(.*?)-->/m) do |match|
      body = Regexp.last_match(1)
      if body.include?('--')
        "<!--#{body.gsub('--', '~~')}-->"
      else
        match
      end
    end
  end

  # Build the recursive key binding setup proc.
  #
  # Returns a proc that processes a +<key>+ XML element and populates the
  # given binding hash. Handles single keys, numeric key codes, multi-key
  # sequences (arrays from KEY_NAME), macro attributes, action attributes,
  # and nested +<key>+ children via self-referencing recursion. A +<key>+
  # whose id names no key is skipped (with any keys nested in it) and logged.
  #
  # A key maps either to a Proc (an action or macro) or to a Hash of the keys
  # that may follow it (a combo prefix), never both. When a definition
  # conflicts with an earlier one of the other kind, the later definition
  # wins -- the same rule that applies when a key is bound twice -- and the
  # conflict is logged.
  #
  # This is a proc (not a method) because it self-references for recursion
  # and creates closures that late-bind to +do_macro+.
  #
  # @param key_action [Hash<String, Proc>] named action procs available for key binding
  # @param do_macro [#call] runs a macro; called with the macro string
  # @return [Proc] a proc accepting (xml_element, binding_hash) that populates bindings
  # @api private
  def build_setup_key(key_action, do_macro)
    setup_key = nil
    setup_key = proc { |xml, binding|
      if (id = xml.attributes['id'])
        key = if id =~ /^[0-9]+$/
                id.to_i
              elsif id.length == 1
                id
              else
                KEY_NAME[id]
              end
        if key
          # A multi-key sequence (e.g. alt+1 => [27, '1']) walks a combo map per prefix key.
          *prefix, final_key = key
          current_binding = prefix.reduce(binding) { |map, k| combo_map_for(map, k, id) }
          if (macro = xml.attributes['macro'])
            bind_key(current_binding, final_key, id, proc { do_macro.call(macro) })
          elsif xml.attributes['action']
            if (action = key_action[xml.attributes['action']])
              bind_key(current_binding, final_key, id, action)
            else
              ProfanityLog.write('settings', "Unknown action '#{xml.attributes['action']}' for key '#{id}'")
            end
          else
            combo = combo_map_for(current_binding, final_key, id)
            xml.elements.each do |e|
              setup_key.call(e, combo)
            end
          end
        else
          ProfanityLog.write('settings', "Unknown key id '#{id}', binding ignored")
        end
      end
    }
  end

  # Bind a key to an action or macro proc. A combo map already at that key
  # is replaced (the later definition wins) and the conflict logged.
  #
  # @param binding [Hash] binding map to modify
  # @param key [Integer, String] key code or character
  # @param id [String] the +<key>+ element's id, for the log message
  # @param handler [Proc] action or macro to run when the key is pressed
  # @return [void]
  # @api private
  def bind_key(binding, key, id, handler)
    log_key_conflict(id, key, 'an action/macro', 'key combo') if binding[key].is_a?(Hash)
    binding[key] = handler
  end

  # Return the combo map for a key, creating it if needed. An action or macro
  # already bound to that key is replaced (the later definition wins) and the
  # conflict logged.
  #
  # @param binding [Hash] binding map to look in
  # @param key [Integer, String] key code or character used as a combo prefix
  # @param id [String] the +<key>+ element's id, for the log message
  # @return [Hash] the combo map of keys that may follow +key+
  # @api private
  def combo_map_for(binding, key, id)
    existing = binding[key]
    return existing if existing.is_a?(Hash)

    log_key_conflict(id, key, 'a key combo prefix', 'action/macro') if existing
    binding[key] = {}
  end

  # Log a key binding conflict between two definitions of different kinds.
  #
  # @param id [String] the id of the later +<key>+ element, which wins
  # @param key [Integer, String] the conflicting key code or character
  # @param new_kind [String] what the later definition uses the key as
  # @param old_kind [String] what the earlier definition bound the key to
  # @return [void]
  # @api private
  def log_key_conflict(id, key, new_kind, old_kind)
    names = KEY_NAME.select { |_name, code| code == key }.keys
    label = names.empty? ? key.inspect : "#{key.inspect} (#{names.join('/')})"
    ProfanityLog.write('settings',
                       "Key binding conflict: <key id='#{id}'> uses key #{label} as #{new_kind}, " \
                       "replacing the earlier #{old_kind} bound to it (later definition wins)")
  end
end
