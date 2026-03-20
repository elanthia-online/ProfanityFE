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

    it 'does not match cmd with double quotes (DR uses single quotes)' do
      # DR protocol uses single quotes for cmd: cmd='...'
      expect(described_class.extract_cmd('<d cmd="go door">')).to be_nil
    end

    it 'handles cmd with apostrophe in value — stops at first single quote' do
      # cmd='it's complicated' would stop at the apostrophe
      result = described_class.extract_cmd("<d cmd='it'>")
      expect(result).to eq 'it'
    end

    it 'handles exist with single quotes (GS uses double quotes)' do
      # GS protocol uses double quotes for exist: exist="..."
      expect(described_class.extract_cmd("<a exist='12345'>")).to be_nil
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

      it 'sets priority to 2 on link color regions' do
        text = "<d cmd='go'>door</d>"
        _, colors = described_class.extract_links(text, links_enabled: true)
        expect(colors.first[:priority]).to eq 2
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
  end
end
