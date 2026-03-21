# frozen_string_literal: true

# Parses .profanity.xml settings and populates global constants
# (HIGHLIGHT, PRESET, LAYOUT, PERC_TRANSFORMS) and gag patterns.

# Lightweight stand-in for REXML::Element that can be Marshal'd.
# Supports the same interface used by SettingsLoader and WindowManager:
# .name, .attributes[], .text, and .elements.each.
class CachedElement
  attr_reader :name, :attributes, :text, :children

  def initialize(name, attributes, text, children)
    @name = name
    @attributes = attributes
    @text = text
    @children = children
  end

  def elements
    @children
  end
end

# Parses a .profanity.xml configuration file and populates global constants.
#
# On initial load, populates PRESET (color presets), LAYOUT (window layouts),
# HIGHLIGHT (regex-based text highlighting), PERC_TRANSFORMS (percWindow text
# substitutions), gag patterns (via GagPatterns), and key bindings.
# On reload, only refreshes HIGHLIGHT, gag patterns, perc-transforms, and
# key bindings -- PRESET and LAYOUT are preserved.
#
# All operations are synchronized through SETTINGS_LOCK to prevent races
# with the server read thread.
#
# @example
#   SettingsLoader.load('char.profanity.xml', key_binding, key_action, do_macro)
#   SettingsLoader.load('char.profanity.xml', key_binding, key_action, do_macro, reload: true)
module SettingsLoader
  module_function

  # Load or reload settings from an XML configuration file.
  #
  # Parses the XML and populates global constants. On initial load
  # (+reload: false+), processes all element types including +preset+
  # and +layout+. On reload (+reload: true+), skips presets and layouts
  # and only refreshes highlights, gag patterns, perc-transforms, and
  # key bindings.
  #
  # @param filename [String] path to the .profanity.xml configuration file
  # @param key_binding [Hash] mutable hash of key bindings to populate
  # @param key_action [Hash<String, Proc>] named action procs available for key binding
  # @param do_macro [Proc] proc that executes a macro string when called
  # @param reload [Boolean] when true, skip PRESET/LAYOUT population and only refresh dynamic settings
  # @return [void]
  # @raise [StandardError] caught internally; prints to $stdout and continues
  def load(filename, key_binding, key_action, do_macro, reload: false)
    setup_key = build_setup_key(key_action, do_macro)

    unless File.exist?(filename)
      warn "Settings file not found: #{filename}"
      return
    end

    SETTINGS_LOCK.synchronize do
      HIGHLIGHT.clear
      PERC_TRANSFORMS.clear
      GagPatterns.clear_custom if reload

      xml_root = load_cached_xml(filename)
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
            HIGHLIGHT[r] = [e.attributes['fg'], e.attributes['bg'], e.attributes['ul']] if r

          when 'key'
            setup_key.call(e, key_binding)

          when 'gag'
            GagPatterns.add_general_pattern(e.text) if e.text && !e.text.strip.empty?

          when 'combat_gag'
            GagPatterns.add_combat_pattern(e.text) if e.text && !e.text.strip.empty?

          when 'perc-transform'
            if e.attributes['pattern']
              begin
                pattern = Regexp.new(e.attributes['pattern'])
                replacement = e.attributes['replace'] || ''
                PERC_TRANSFORMS.push([pattern, replacement])
              rescue RegexpError => e_err
                warn "Invalid perc-transform pattern: #{e.attributes['pattern']} - #{e_err}"
              end
            end
          end

          # Presets and layouts are only loaded on initial load, not reload
          next if reload

          case e.name
          when 'preset'
            PRESET[e.attributes['id']] = [e.attributes['fg'], e.attributes['bg']]
          when 'layout'
            LAYOUT[e.attributes['id']] = e if e.attributes['id']
          end
        end
    end
  rescue StandardError => e
    ProfanityLog.write('settings', e.message, backtrace: e.backtrace)
  end

  # Load the XML settings, using a Marshal cache when possible.
  # If the cache file exists and is newer than the XML source, the cached
  # CachedElement tree is returned directly (~1ms). Otherwise the XML is
  # parsed with REXML, converted to CachedElements, and cached for next time.
  #
  # @param filename [String] path to the .profanity.xml file
  # @return [CachedElement] root element of the parsed settings
  def load_cached_xml(filename)
    cache_file = cache_path_for(filename)

    if cache_file && File.exist?(cache_file) && File.mtime(cache_file) >= File.mtime(filename)
      begin
        return Marshal.load(File.binread(cache_file))
      rescue StandardError
        # Cache corrupt or incompatible -- fall through to full parse
      end
    end

    xml_string = sanitize_xml_comments(File.read(filename))
    xml_doc = REXML::Document.new(xml_string)
    cached_root = rexml_to_cached(xml_doc.root)

    if cache_file
      begin
        File.binwrite(cache_file, Marshal.dump(cached_root))
      rescue StandardError => e
        ProfanityLog.write('settings', "Failed to write settings cache: #{e.message}")
      end
    end

    cached_root
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
  # Cache lives in ~/.profanity/ alongside log files.
  #
  # @param filename [String] path to the XML file
  # @return [String, nil] cache path, or nil if APP_DIR is unavailable
  def cache_path_for(filename)
    dir = defined?(ProfanitySettings::APP_DIR) ? ProfanitySettings::APP_DIR : nil
    return nil unless dir

    basename = File.basename(filename, File.extname(filename))
    File.join(dir, "#{basename}.settings.cache")
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
  # and nested +<key>+ children via self-referencing recursion.
  #
  # This is a proc (not a method) because it self-references for recursion
  # and creates closures that late-bind to +do_macro+.
  #
  # @param key_action [Hash<String, Proc>] named action procs available for key binding
  # @param do_macro [Proc] proc that executes a macro string when called
  # @return [Proc] a proc accepting (xml_element, binding_hash) that populates bindings
  # @api private
  def build_setup_key(key_action, do_macro)
    setup_key = nil
    setup_key = proc { |xml, binding|
      if (key = xml.attributes['id'])
        if key =~ /^[0-9]+$/
          key = key.to_i
        elsif key.instance_of?(String) && (key.length == 1)
          nil
        else
          key = KEY_NAME[key]
        end
        if key
          if key.instance_of?(Array)
            current_binding = binding
            key[0..-2].each do |k|
              current_binding[k] ||= {}
              current_binding = current_binding[k]
            end
            final_key = key[-1]
            if (macro = xml.attributes['macro'])
              current_binding[final_key] = proc { do_macro.call(macro) }
            elsif xml.attributes['action']
              if (action = key_action[xml.attributes['action']])
                current_binding[final_key] = action
              else
                ProfanityLog.write('settings', "Unknown action '#{xml.attributes['action']}' for key '#{xml.attributes['id']}'")
              end
            else
              current_binding[final_key] ||= {}
              xml.elements.each do |e|
                setup_key.call(e, current_binding[final_key])
              end
            end
          elsif (macro = xml.attributes['macro'])
            binding[key] = proc { do_macro.call(macro) }
          elsif xml.attributes['action']
            if (action = key_action[xml.attributes['action']])
              binding[key] = action
            else
              ProfanityLog.write('settings', "Unknown action '#{xml.attributes['action']}' for key '#{xml.attributes['id']}'")
            end
          else
            binding[key] ||= {}
            xml.elements.each do |e|
              setup_key.call(e, binding[key])
            end
          end
        end
      end
    }
  end
end
