# frozen_string_literal: true

# Tests XmlTokenizer: .tokenize splits game server lines into [:text, ...]
# and [:tag, ...] segments; .tag_name extracts element names from raw tags.
# Covers paired tags, self-closing tags, nested content, entities, and
# adversarial malformed input.

require_relative '../../lib/xml_tokenizer'

RSpec.describe XmlTokenizer do
  describe '.tokenize' do
    # ---- Basic behavior ----

    it 'returns empty array for empty string' do
      expect(described_class.tokenize('')).to eq []
    end

    it 'returns single text segment for tagless input' do
      expect(described_class.tokenize('Hello world')).to eq [[:text, 'Hello world']]
    end

    it 'returns single tag segment for tag-only input' do
      expect(described_class.tokenize('<pushBold/>')).to eq [[:tag, '<pushBold/>']]
    end

    # ---- Boundary conditions ----

    it 'handles a single character' do
      expect(described_class.tokenize('x')).to eq [[:text, 'x']]
    end

    it 'handles whitespace-only input' do
      expect(described_class.tokenize('   ')).to eq [[:text, '   ']]
    end

    it 'handles tag at very start of line with no trailing text' do
      result = described_class.tokenize('<pushBold/>text')
      expect(result.first).to eq [:tag, '<pushBold/>']
    end

    it 'handles tag at very end of line with no leading text' do
      result = described_class.tokenize('text<pushBold/>')
      expect(result.last).to eq [:tag, '<pushBold/>']
    end

    it 'handles consecutive tags with no text between them' do
      result = described_class.tokenize('<pushBold/><popBold/>')
      expect(result).to eq [[:tag, '<pushBold/>'], [:tag, '<popBold/>']]
    end

    it 'handles three consecutive tags' do
      result = described_class.tokenize('<a/><b/><c/>')
      expect(result.length).to eq 3
      expect(result.map(&:first)).to all(eq :tag)
    end

    # ---- Malformed / adversarial input ----

    it 'treats bare < without closing > as plain text' do
      # A lone < should not be treated as a tag start if there's no >
      result = described_class.tokenize('5 < 10')
      # The regex <[^>]*> requires at least one > after <
      # If < appears without >, it stays as text
      texts = result.select { |type, _| type == :text }.map(&:last).join
      expect(texts).to include('<')
    end

    it 'treats bare > as plain text' do
      result = described_class.tokenize('5 > 3')
      texts = result.select { |type, _| type == :text }.map(&:last).join
      expect(texts).to include('>')
    end

    it 'handles empty tag <>' do
      result = described_class.tokenize('<>')
      # <> matches <[^>]*> with zero chars between < and >
      expect(result).to eq [[:tag, '<>']]
    end

    it 'handles tag with only whitespace inside' do
      result = described_class.tokenize('< >')
      expect(result).to eq [[:tag, '< >']]
    end

    it 'preserves entity-encoded angle brackets as text' do
      result = described_class.tokenize('&lt;not a tag&gt;')
      expect(result).to eq [[:text, '&lt;not a tag&gt;']]
    end

    it 'does not choke on very long lines' do
      long_text = 'a' * 10_000
      result = described_class.tokenize(long_text)
      expect(result).to eq [[:text, long_text]]
    end

    it 'does not choke on many tags in one line' do
      tags = '<x/>' * 500
      result = described_class.tokenize(tags)
      expect(result.length).to eq 500
    end

    it 'handles newlines within text segments' do
      result = described_class.tokenize("line1\nline2")
      expect(result).to eq [[:text, "line1\nline2"]]
    end

    it 'handles tab characters in text' do
      result = described_class.tokenize("col1\tcol2")
      expect(result).to eq [[:text, "col1\tcol2"]]
    end

    # ---- Paired tag edge cases ----

    it 'captures paired prompt tag as single segment including content' do
      xml = '<prompt time="123">H&gt;</prompt>'
      result = described_class.tokenize(xml)
      expect(result).to eq [[:tag, xml]]
    end

    it 'captures prompt with unusual content' do
      xml = '<prompt time="0">S&gt;</prompt>'
      result = described_class.tokenize(xml)
      expect(result).to eq [[:tag, xml]]
    end

    it 'captures spell tag with empty spell name' do
      result = described_class.tokenize('<spell></spell>')
      expect(result).to eq [[:tag, '<spell></spell>']]
    end

    it 'captures compass with no directions' do
      result = described_class.tokenize('<compass></compass>')
      expect(result).to eq [[:tag, '<compass></compass>']]
    end

    it 'handles text between two paired tags' do
      line = '<spell>Fire</spell> and <spell>Ice</spell>'
      result = described_class.tokenize(line)
      expect(result).to eq [
        [:tag, '<spell>Fire</spell>'],
        [:text, ' and '],
        [:tag, '<spell>Ice</spell>'],
      ]
    end

    # ---- Game protocol realism ----

    it 'handles a full room description line with mixed tags' do
      line = '<style id="roomName"/>[Town Square]<style id=""/>  You stand in the center of town.'
      result = described_class.tokenize(line)
      expect(result[0]).to eq [:tag, '<style id="roomName"/>']
      expect(result[1]).to eq [:text, '[Town Square]']
      expect(result[2]).to eq [:tag, '<style id=""/>']
      expect(result[3]).to eq [:text, '  You stand in the center of town.']
    end

    it 'handles progressBar self-closing tag' do
      xml = %q{<progressBar id='health' value='75' text='health 75%'/>}
      result = described_class.tokenize(xml)
      expect(result).to eq [[:tag, xml]]
    end

    it 'handles indicator self-closing tag' do
      xml = %q{<indicator id='IconSTUNNED' visible='y'/>}
      result = described_class.tokenize(xml)
      expect(result).to eq [[:tag, xml]]
    end

    it 'handles mixed bold + link tags' do
      line = '<pushBold/><a exist="123" noun="goblin">a goblin</a><popBold/>'
      result = described_class.tokenize(line)
      tags = result.select { |type, _| type == :tag }
      texts = result.select { |type, _| type == :text }
      expect(tags.length).to eq 4
      expect(texts.length).to eq 1
      expect(texts.first.last).to eq 'a goblin'
    end

    # ---- Adversarial: attribute edge cases ----

    it 'handles attributes containing > inside quotes' do
      line = %q{<prompt time="123">H&gt;</prompt>}
      result = described_class.tokenize(line)
      expect(result.first[0]).to eq :tag
    end

    it 'handles self-closing tags with extra spaces' do
      result = described_class.tokenize('<pushBold  />')
      expect(result.first).to eq [:tag, '<pushBold  />']
    end

    it 'handles deeply nested content (10 levels of tags)' do
      inner = 'deep text'
      10.times { inner = "<b>#{inner}</b>" }
      result = described_class.tokenize(inner)
      texts = result.select { |type, _| type == :text }
      expect(texts.length).to eq 1
      expect(texts.first.last).to eq 'deep text'
    end

    it 'handles tags with single-quoted and double-quoted attributes on same line' do
      line = %q{<preset id='roomDesc'><style id="roomName"/>}
      result = described_class.tokenize(line)
      expect(result.length).to eq 2
      expect(result).to all(satisfy { |type, _| type == :tag })
    end
  end

  describe '.tag_name' do
    it 'extracts name from self-closing tags' do
      expect(described_class.tag_name('<pushBold/>')).to eq 'pushBold'
    end

    it 'extracts name from opening tags with attributes' do
      expect(described_class.tag_name('<style id="roomName">')).to eq 'style'
    end

    it 'extracts name from closing tags' do
      expect(described_class.tag_name('</preset>')).to eq 'preset'
    end

    it 'extracts name from self-closing tags with trailing space' do
      expect(described_class.tag_name('<popStream id="combat" />')).to eq 'popStream'
    end

    it 'extracts name from single-letter tags' do
      expect(described_class.tag_name('<b>')).to eq 'b'
      expect(described_class.tag_name('</b>')).to eq 'b'
      expect(described_class.tag_name('<d>')).to eq 'd'
      expect(described_class.tag_name('</d>')).to eq 'd'
      expect(described_class.tag_name('<a href="x">')).to eq 'a'
    end

    it 'handles tags with numeric characters in name' do
      # Not used in protocol but shouldn't crash
      expect(described_class.tag_name('<h1>')).to eq 'h1'
    end

    it 'returns nil for empty tag <>' do
      expect(described_class.tag_name('<>')).to be_nil
    end

    it 'returns nil for closing tag with no name </>' do
      expect(described_class.tag_name('</>')).to be_nil
    end
  end
end
