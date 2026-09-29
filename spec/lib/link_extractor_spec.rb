# frozen_string_literal: true

# Tests LinkExtractor: extract_cmd for GS <a exist/noun> and DR <d cmd>
# tags, extract_links_from_text for inline link discovery with color
# regions, and DEFAULT_LINK_COLOR constant.

require_relative '../../lib/link_extractor'

RSpec.describe LinkExtractor do
  describe '.extract_cmd' do
    # ---- DR format: cmd attribute ----

    it 'extracts cmd from DR <d> tag' do
      expect(described_class.extract_cmd("<d cmd='go door'>")).to eq 'go door'
    end

    it 'extracts cmd with spaces and special characters' do
      expect(described_class.extract_cmd("<d cmd='get #40872332'>")).to eq 'get #40872332'
    end

    it 'extracts cmd with multi-word command' do
      expect(described_class.extract_cmd("<d cmd='go northwest gate'>")).to eq 'go northwest gate'
    end

    # ---- GS format: exist + noun attributes ----

    it 'builds look command from exist + noun' do
      expect(described_class.extract_cmd('<a exist="12345" noun="sword">')).to eq 'look #12345'
    end

    it 'builds _drag command from exist without noun' do
      expect(described_class.extract_cmd('<a exist="12345">')).to eq '_drag #12345'
    end

    it 'handles exist with large ID numbers' do
      expect(described_class.extract_cmd('<a exist="999999999" noun="thing">')).to eq 'look #999999999'
    end

    # ---- No cmd/exist ----

    it 'returns nil when no cmd or exist attribute' do
      expect(described_class.extract_cmd('<d>')).to be_nil
    end

    it 'returns nil for <a> without attributes' do
      expect(described_class.extract_cmd('<a>')).to be_nil
    end

    # ---- Adversarial ----

    it 'returns nil for empty string' do
      expect(described_class.extract_cmd('')).to be_nil
    end

    it 'extracts cmd in double quotes, as DR sends in FLAG output' do
      expect(described_class.extract_cmd('<d cmd="flag LogOn on">')).to eq 'flag LogOn on'
    end

    it 'keeps an apostrophe inside a double-quoted cmd' do
      expect(described_class.extract_cmd(%(<d cmd="look Bob's sword">))).to eq "look Bob's sword"
    end

    it 'ends a single-quoted cmd at the next single quote (an unescaped apostrophe is malformed markup)' do
      expect(described_class.extract_cmd("<d cmd='look Bob's sword'>")).to eq 'look Bob'
    end

    it 'reads exist in single quotes too (GS sends double quotes)' do
      expect(described_class.extract_cmd("<a exist='12345'>")).to eq '_drag #12345'
    end

    # Which spellings of a link tag give which command: quote style,
    # attribute order, names that merely contain cmd/exist/noun, empty values.
    it 'reads cmd, exist and noun only from attributes with exactly those names' do
      {
        "<d  cmd='go'>"               => 'go',
        "<d x='1' cmd='go'>"          => 'go',
        "<d xcmd='go'>"               => nil,
        %(<d title="cmd='go'">)       => nil,
        "<d cmd='' cmd='go'>"         => nil,
        "<d cmd=''>"                  => nil,
        '<a exist="1" noun="sword">'  => 'look #1',
        '<a noun="sword" exist="1">'  => 'look #1',
        %(<a exist="1" noun='sword'>) => 'look #1',
        '<a exist="1" xnoun="sword">' => '_drag #1',
        '<a pexist="1">'              => nil,
        '<a exist="">'                => nil,
        %(<a exist="1" noun="">)      => '_drag #1',
        "<a exist='1' cmd='go'>"      => 'go',
        '<a exist="1" cmd="">'        => '_drag #1'
      }.each do |tag, cmd|
        expect(described_class.extract_cmd(tag)).to eq(cmd), tag
      end
    end
  end

  describe '.extract_links' do
    # ---- Links enabled ----

    context 'with links enabled' do
      it 'extracts DR <d> link with cmd attribute' do
        text = "Go through <d cmd='go door'>the door</d>."
        clean, colors = described_class.extract_links(text, links_enabled: true)
        expect(clean).to eq 'Go through the door.'
        link = colors.find { |c| c[:cmd] }
        expect(link[:cmd]).to eq 'go door'
        expect(link[:start]).to eq 11
        expect(link[:end]).to eq 19
      end

      it 'extracts GS <a> link with exist/noun' do
        text = '<a exist="12345" noun="sword">a sword</a>'
        clean, colors = described_class.extract_links(text, links_enabled: true)
        expect(clean).to eq 'a sword'
        expect(colors.first[:cmd]).to eq 'look #12345'
      end

      it 'uses link text as fallback cmd when no attributes' do
        text = '<d>north</d>'
        clean, colors = described_class.extract_links(text, links_enabled: true)
        expect(clean).to eq 'north'
        expect(colors.first[:cmd]).to eq 'north'
      end

      it 'handles multiple links in one string' do
        text = "Go <d cmd='go north'>north</d> or <d cmd='go south'>south</d>."
        clean, colors = described_class.extract_links(text, links_enabled: true)
        expect(clean).to eq 'Go north or south.'
        expect(colors.length).to eq 2
        expect(colors[0][:cmd]).to eq 'go north'
        expect(colors[1][:cmd]).to eq 'go south'
      end

      it 'uses DEFAULT_LINK_COLOR when no preset defined' do
        PRESET.delete('links')
        text = "<d cmd='go'>door</d>"
        _, colors = described_class.extract_links(text, links_enabled: true)
        expect(colors.first[:fg]).to eq '5555ff'
      end

      it 'uses PRESET links color when defined' do
        PRESET['links'] = ['ff0000', '000000']
        text = "<d cmd='go'>door</d>"
        _, colors = described_class.extract_links(text, links_enabled: true)
        expect(colors.first[:fg]).to eq 'ff0000'
        expect(colors.first[:bg]).to eq '000000'
      end

      it 'accepts explicit link_preset parameter' do
        text = "<d cmd='go'>door</d>"
        _, colors = described_class.extract_links(text, links_enabled: true, link_preset: ['aabbcc', nil])
        expect(colors.first[:fg]).to eq 'aabbcc'
      end

      it 'color positions are correct after multiple link extractions' do
        text = "A <d>north</d> B <d>south</d> C"
        clean, colors = described_class.extract_links(text, links_enabled: true)
        expect(clean).to eq 'A north B south C'

        north = colors.find { |c| c[:cmd] == 'north' }
        south = colors.find { |c| c[:cmd] == 'south' }
        expect(clean[north[:start]...north[:end]]).to eq 'north'
        expect(clean[south[:start]...south[:end]]).to eq 'south'
      end

      it 'strips remaining XML tags after link extraction' do
        text = "<pushBold/><d cmd='go'>door</d><popBold/>"
        clean, _ = described_class.extract_links(text, links_enabled: true)
        expect(clean).to eq 'door'
        expect(clean).not_to include('<')
      end
    end

    # ---- Links disabled ----

    context 'with links disabled' do
      it 'strips link tags but keeps text content' do
        text = "Go through <d cmd='go door'>the door</d>."
        clean, colors = described_class.extract_links(text, links_enabled: false)
        expect(clean).to eq 'Go through the door.'
        expect(colors).to be_empty
      end

      it 'strips <a> tags too' do
        text = '<a exist="12345" noun="sword">a sword</a>'
        clean, colors = described_class.extract_links(text, links_enabled: false)
        expect(clean).to eq 'a sword'
        expect(colors).to be_empty
      end

      it 'strips remaining XML tags' do
        text = '<pushBold/>bold text<popBold/>'
        clean, _ = described_class.extract_links(text, links_enabled: false)
        expect(clean).to eq 'bold text'
      end
    end

    # ---- Adversarial ----

    context 'adversarial inputs' do
      it 'handles empty string' do
        clean, colors = described_class.extract_links('', links_enabled: true)
        expect(clean).to eq ''
        expect(colors).to be_empty
      end

      it 'handles text with no tags' do
        clean, colors = described_class.extract_links('plain text', links_enabled: true)
        expect(clean).to eq 'plain text'
        expect(colors).to be_empty
      end

      it 'handles link with empty text content' do
        text = "<d cmd='go'></d>"
        clean, colors = described_class.extract_links(text, links_enabled: true)
        expect(clean).to eq ''
        # Zero-length link — cmd from attribute, not fallback
        expect(colors.first[:cmd]).to eq 'go'
        expect(colors.first[:start]).to eq colors.first[:end]
      end

      it 'handles nested tags inside link text' do
        # GS sometimes has <a> around <pushBold/> text
        text = "<a exist=\"123\" noun=\"goblin\"><pushBold/>a goblin</a>"
        clean, colors = described_class.extract_links(text, links_enabled: true)
        # The <pushBold/> inside the link text gets stripped by the catch-all
        expect(clean).not_to include('<')
        expect(colors.first[:cmd]).to eq 'look #123'
      end

      it 'handles unclosed link tag (no matching </d>)' do
        text = "<d cmd='go'>orphaned text"
        clean, _ = described_class.extract_links(text, links_enabled: true)
        # No match for the regex — tag stays, then gets stripped by catch-all
        expect(clean).to eq 'orphaned text'
      end

      it 'handles adjacent links with no space between' do
        text = "<d>north</d><d>south</d>"
        clean, colors = described_class.extract_links(text, links_enabled: true)
        expect(clean).to eq 'northsouth'
        expect(colors.length).to eq 2
        expect(colors[0][:end]).to eq colors[1][:start]
      end

      it 'does not match <div> or other tags starting with d' do
        text = '<div>content</div>'
        _, colors = described_class.extract_links(text, links_enabled: true)
        # <div> should NOT match <d> link pattern — the regex requires </d> or </a>
        # But <div> matches <([ad])...> where \1 = 'd' and closing is </d>iv> — no match
        # Actually <div> matches <([ad])\s?... with 'd', then looks for </d> — 'iv>' != closing
        # The regex is </\1>, so for 'd' it looks for </d>. </div> is not </d>.
        expect(colors).to be_empty
      end

      it 'handles very long link text' do
        long_text = 'a' * 10_000
        text = "<d cmd='go'>#{long_text}</d>"
        clean, colors = described_class.extract_links(text, links_enabled: true)
        expect(clean).to eq long_text
        expect(colors.first[:end] - colors.first[:start]).to eq 10_000
      end

      it 'handles entity-encoded text inside links (entities stay encoded)' do
        text = "<d cmd='go'>the &amp; door</d>"
        clean, _ = described_class.extract_links(text, links_enabled: true)
        # LinkExtractor does NOT unescape entities — that's the caller's job
        expect(clean).to eq 'the &amp; door'
      end

      it 'pre-strips non-link XML so <b> tags do not cause link position drift' do
        # Real game data: monster bold wraps a linked creature
        text = 'the <a exist="-2078" noun="Lodge">Wayside Lodge</a> and<b> a <a exist="-477668" noun="assistant">dwarven blacksmith assistant</a></b>.'
        clean, colors = described_class.extract_links(text, links_enabled: true)

        expect(clean).to eq 'the Wayside Lodge and a dwarven blacksmith assistant.'

        lodge_link = colors.find { |c| c[:cmd] == 'look #-2078' }
        assistant_link = colors.find { |c| c[:cmd] == 'look #-477668' }

        # Link regions must match the actual character positions in clean_text
        expect(clean[lodge_link[:start]...lodge_link[:end]]).to eq 'Wayside Lodge'
        expect(clean[assistant_link[:start]...assistant_link[:end]]).to eq 'dwarven blacksmith assistant'
      end

      it 'pre-strips <style> tags without affecting link positions' do
        text = '<style id=""/>You see <a exist="123" noun="sword">a sword</a> here.'
        clean, colors = described_class.extract_links(text, links_enabled: true)

        expect(clean).to eq 'You see a sword here.'
        expect(clean[colors.first[:start]...colors.first[:end]]).to eq 'a sword'
      end
    end

    # What extract_links makes of each spelling of link markup: the clean
    # text, and each link as [start, end, cmd]; and the clean text with links
    # off (the same text, no links).
    describe 'acceptance' do
      # @param text [String] the markup
      # @return [Array(String, Array<Array>, String)]
      def extracted(text)
        clean, colors = described_class.extract_links(text, links_enabled: true)
        off, off_colors = described_class.extract_links(text, links_enabled: false)
        raise "links off gave colors for #{text}" unless off_colors.empty?

        [clean, colors.map { |c| [c[:start], c[:end], c[:cmd]] }, off]
      end

      def expect_each(table)
        table.each { |text, expected| expect(extracted(text)).to eq(expected), text }
      end

      it 'reads well-formed links in either quotes' do
        expect_each(
          "<d cmd='go'>door</d>"          => ['door', [[0, 4, 'go']], 'door'],
          '<d cmd="go">door</d>'          => ['door', [[0, 4, 'go']], 'door'],
          %(<d cmd="a'b">x</d>)           => ['x', [[0, 1, "a'b"]], 'x'],
          "<d\tcmd='go'>n</d>"            => ['n', [[0, 1, 'go']], 'n'],
          "<d  cmd='go'>n</d>"            => ['n', [[0, 1, 'go']], 'n'],
          "<d>n</d><d>s</d>"              => ['ns', [[0, 1, 'n'], [1, 2, 's']], 'ns'],
          "<d>n</d> <a exist='1'>s</a>"   => ['n s', [[0, 1, 'n'], [2, 3, '_drag #1']], 'n s'],
          '<d></d>'                       => ['', [[0, 0, '']], ''],
          "<d cmd='go'></d>"              => ['', [[0, 0, 'go']], ''],
          "<d cmd='a'b'>x</d>"            => ['x', [[0, 1, 'a']], 'x'],
          '<d>a<b>b</b>c</d>'             => ['abc', [[0, 3, 'abc']], 'abc'],
          '<b>x</b><d>y</d>'              => ['xy', [[1, 2, 'y']], 'xy'],
          '<right>sword</right> <d>n</d>' => ['sword n', [[6, 7, 'n']], 'sword n'],
          "Also here: <a exist='1' noun='Bob'>Bob</a> and <d cmd='look Al'>Al</d>." =>
            ['Also here: Bob and Al.', [[11, 14, 'look #1'], [19, 21, 'look Al']], 'Also here: Bob and Al.']
        )
      end

      it 'pairs each end tag with the earliest open link of its element; tags never count as link text' do
        expect_each(
          '<d>a<d>b</d>c</d>'  => ['abc', [[0, 2, 'ab'], [1, 3, 'bc']], 'abc'],
          '<a>x<d>y</d></a>'   => ['xy', [[0, 2, 'xy'], [1, 2, 'y']], 'xy'],
          # an unpaired link tag is dropped and takes no room
          '<a>x<d>y</d>'       => ['xy', [[1, 2, 'y']], 'xy'],
          '</d><d>n</d>'       => ['n', [[0, 1, 'n']], 'n'],
          "<d cmd='go'>orphan" => ['orphan', [], 'orphan'],
          '<a>x</d>'           => ['x', [], 'x']
        )
      end

      it 'counts every tag the dispatcher reads as a or d as a link tag' do
        expect_each(
          '<d/>n</d>'  => ['n', [[0, 1, 'n']], 'n'],
          '<a-b>x</a>' => ['x', [[0, 1, 'x']], 'x'],
          '<a<b>x</a>' => ['x', [[0, 1, 'x']], 'x'],
          '<dx>n</dx>' => ['n', [], 'n']
        )
      end

      it 'keeps a > inside a quoted value within its tag' do
        expect_each(
          "<d cmd='a>b'>x</d>" => ['x', [[0, 1, 'a>b']], 'x'],
          "<b t='>'><d>n</d>"  => ['n', [[0, 1, 'n']], 'n'],
          "<d x='<'>n</d>"     => ['n', [[0, 1, 'n']], 'n'],
          'x <b <d>y</d>'      => ['x y', [], 'x y']
        )
      end

      it 'removes <> like any other tag' do
        expect_each(
          'x <> y'     => ['x  y', [], 'x  y'],
          '<d>a</d><>' => ['a', [[0, 1, 'a']], 'a']
        )
      end
    end
  end
end
