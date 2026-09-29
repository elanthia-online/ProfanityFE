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

    it 'keeps a paired prompt tag whole when its content holds an escaped >' do
      line = %q{<prompt time="123">H&gt;</prompt>}
      expect(described_class.tokenize(line)).to eq [[:tag, line]]
    end

    it 'keeps a > inside a quoted attribute value within the tag' do
      line = %q{<d cmd="look >here">text</d>}
      expect(described_class.tokenize(line))
        .to eq [[:tag, '<d cmd="look >here">'], [:text, 'text'], [:tag, '</d>']]
    end

    it 'keeps a > inside a single-quoted attribute value within the tag' do
      line = %q{<d cmd='look >here'>text</d>}
      expect(described_class.tokenize(line))
        .to eq [[:tag, %q{<d cmd='look >here'>}], [:text, 'text'], [:tag, '</d>']]
    end

    it 'keeps later attributes after a quoted value holding a >' do
      line = %q{<d cmd="a > b" id='x' noun="y">text</d>}
      expect(described_class.tokenize(line))
        .to eq [[:tag, %q{<d cmd="a > b" id='x' noun="y">}], [:text, 'text'], [:tag, '</d>']]
    end

    it 'still ends the tag at an unquoted >' do
      line = %q{<d cmd=look>here">text</d>}
      expect(described_class.tokenize(line))
        .to eq [[:tag, '<d cmd=look>'], [:text, 'here">text'], [:tag, '</d>']]
    end

    it 'splits a line of several tags with quoted > values' do
      line = %q{<pushBold/><d cmd="go >gate">the gate</d> and <a exist="1" noun='x>y'>a box</a><popBold/>}
      expect(described_class.tokenize(line)).to eq [
        [:tag, '<pushBold/>'], [:tag, '<d cmd="go >gate">'], [:text, 'the gate'], [:tag, '</d>'],
        [:text, ' and '], [:tag, %q{<a exist="1" noun='x>y'>}], [:text, 'a box'], [:tag, '</a>'],
        [:tag, '<popBold/>']
      ]
    end

    it 'ends a tag with an unbalanced quote at its first >, not in the next tag' do
      line = %q{<d cmd='Bob's hat'>Bob's hat</d>}
      expect(described_class.tokenize(line))
        .to eq [[:tag, %q{<d cmd='Bob's hat'>}], [:text, "Bob's hat"], [:tag, '</d>']]
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

  describe '.tokenize with paired: false' do
    it 'splits a paired tag into its start tag, content and end tag' do
      expect(described_class.tokenize("<prompt time='1'>H&gt;</prompt>x", paired: false))
        .to eq [[:tag, "<prompt time='1'>"], [:text, 'H&gt;'], [:tag, '</prompt>'], [:text, 'x']]
    end

    it 'finds tags inside what would be a paired tag\'s content' do
      expect(described_class.tokenize('<compass><dir value="n"/></compass>', paired: false).map(&:last))
        .to eq ['<compass>', '<dir value="n"/>', '</compass>']
    end

    it 'reads every other tag as the paired tokenizer does' do
      [
        %(<d cmd="look >here">x</d>),
        %(<b t="x>y" u='a>b'/>tail<popBold/>),
        %(<a x="1>2 <b>3</b>),
        '5 < 10 > 3 <> < >',
        %(<pushStream id="combat"/><preset id='speech'>Hi</preset>)
      ].each do |line|
        expect(described_class.tokenize(line, paired: false)).to eq(described_class.tokenize(line)), line
      end
    end

    it 'gives back the line when the segments are joined' do
      ["<prompt>a</prompt><spell x='>'>b</spell>c", '<left>x', "</right><inv id='1'><a>y</a></inv>"].each do |line|
        expect(described_class.tokenize(line, paired: false).map(&:last).join).to eq(line)
      end
    end
  end

  describe '.tags' do
    it 'lists the tags of a line in order, without the text' do
      expect(described_class.tags("a <pushBold/>b<popBold/> c")).to eq ['<pushBold/>', '<popBold/>']
    end

    it 'keeps a paired tag whole unless told otherwise' do
      line = "<spell>x</spell><popBold/>"
      expect(described_class.tags(line)).to eq ['<spell>x</spell>', '<popBold/>']
      expect(described_class.tags(line, paired: false)).to eq ['<spell>', '</spell>', '<popBold/>']
    end

    it 'returns nothing for a line without tags' do
      expect(described_class.tags('5 < 10')).to eq []
    end
  end

  describe '.content' do
    def content(xml) = described_class.content(xml)

    it 'returns the text between the start tag and the end tag' do
      expect(content('<right exist="1" noun="sword">steel sword</right>')).to eq 'steel sword'
      expect(content("<prompt time='1727'>H&gt;</prompt>")).to eq 'H&gt;'
    end

    it 'starts after the whole start tag when a quoted value holds a >' do
      expect(content('<right exist="1" noun="a>b">sword</right>')).to eq 'sword'
      expect(content("<spell id='x>y' z=\"1>2\">Fire</spell>")).to eq 'Fire'
      expect(content('<prompt time="1" s="a>b">H&gt;</prompt>')).to eq 'H&gt;'
    end

    it 'returns an empty string for an element with no content' do
      expect(content('<spell></spell>')).to eq ''
      expect(content('<right exist="1"></right>')).to eq ''
    end

    it 'keeps tags and entities in the content as sent' do
      expect(content('<compass><dir value="n"/></compass>')).to eq '<dir value="n"/>'
      expect(content('<left>a &lt;red&gt; &amp; blue gem</left>')).to eq 'a &lt;red&gt; &amp; blue gem'
    end

    it 'ends at the first end tag of the same name, as the tokenizer pairs them' do
      expect(content('<right><right>x</right></right>')).to eq '<right>x'
      expect(described_class.tags('<right><right>x</right></right>').first).to eq '<right><right>x</right>'
      expect(content('<right><left>x</left>y</right>')).to eq '<left>x</left>y'
    end

    it 'returns nil for an element with no end tag' do
      expect(content('<left>sword')).to be_nil
      expect(content('<left>sword</right>')).to be_nil
      expect(content('<left>sword</left')).to be_nil
    end

    it 'returns nil for a self-closing tag, even with an end tag after it' do
      expect(content('<spell/>')).to be_nil
      expect(content('<right noun="x" />')).to be_nil
      expect(content('<spell/>Fire</spell>')).to be_nil
      expect(content('<spell />Fire</spell>')).to be_nil
    end

    it 'returns nil for an end tag, plain text, an unclosed start tag or an empty string' do
      ['</spell>', 'Fire</spell>', '<spell', '<spell id="x"', '', '<>Fire</>'].each do |xml|
        expect(content(xml)).to be_nil, xml
      end
    end

    it 'reads the element name exactly: no end tag closes a longer name' do
      expect(content('<right-x>sword</right>')).to be_nil
      expect(content('<rightx>sword</right>')).to be_nil
    end

    it 'ends a start tag with an unbalanced quote at its first >, as the tokenizer does' do
      xml = '<right noun="a>sword</right>'
      expect(described_class.tokenize(xml, paired: false).first).to eq [:tag, '<right noun="a>']
      expect(content(xml)).to eq 'sword'
    end
  end

  describe '.start_tag_name' do
    it 'names start tags and empty-element tags, not end tags' do
      {
        '<pushStream id="combat"/>' => 'pushStream',
        "<preset id='x'>"           => 'preset',
        '<prompt>H&gt;</prompt>'    => 'prompt',
        '<pushBold-x/>'             => 'pushBold',
        '</preset>'                 => nil,
        '</popStream>'              => nil,
        '<>'                        => nil,
        '< b>'                      => nil
      }.each do |tag, name|
        expect(described_class.start_tag_name(tag)).to eq(name), tag
      end
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

  describe 'PAIRED_TAGS' do
    it 'keeps each paired element whole with its content, and nothing else' do
      described_class::PAIRED_TAGS.each do |name|
        line = %(<#{name} id='x'>a <b>b</b> c</#{name}>tail)
        expect(described_class.tokenize(line)).to eq([[:tag, line.delete_suffix('tail')], [:text, 'tail']]), name
      end
      expect(described_class.tokenize('<preset id="x">text</preset>').size).to eq 3
    end
  end

  describe '.attrs' do
    def attrs(tag) = described_class.attrs(tag)

    it 'reads values in double and in single quotes' do
      expect(attrs(%(<d cmd='go door' noun="door">))).to eq('cmd' => 'go door', 'noun' => 'door')
    end

    it 'keeps > and the other quote inside a quoted value' do
      expect(attrs(%(<d cmd='say "hi" >there' x="Bob's >">))).to eq('cmd' => 'say "hi" >there', 'x' => "Bob's >")
    end

    it 'ends a value at its own quote, so the rest of the tag is not an attribute' do
      expect(attrs("<d cmd='look Bob's sword'>")).to eq('cmd' => 'look Bob')
    end

    it 'has no key for a missing attribute' do
      expect(attrs("<roundTime value='5'/>")).not_to have_key('id')
    end

    it 'keeps the first of two attributes with the same name' do
      expect(attrs(%(<pushStream id="combat" id='familiar'/>))).to eq('id' => 'combat')
    end

    it 'reads an empty value as an empty string' do
      expect(attrs(%(<style id=""/>))).to eq('id' => '')
      expect(attrs("<style id=''/>")).to eq('id' => '')
    end

    it 'reads self-closing tags, with or without a space before />' do
      expect(attrs(%(<popStream id="combat"/>))).to eq('id' => 'combat')
      expect(attrs(%(<popStream id="combat" />))).to eq('id' => 'combat')
    end

    it 'matches names exactly, not as a prefix or suffix of another name' do
      expect(attrs(%(<pushStream pid="a" idx='b' x-id="c" data.id='d'/>)).keys).to eq %w[pid idx x-id data.id]
      expect(attrs(%(<pushStream pid="a" id='b'/>))['id']).to eq 'b'
    end

    it 'does not read attribute-like text inside another value' do
      expect(attrs(%(<pushStream subtitle="x id='combat'" id="room"/>))).to eq('subtitle' => "x id='combat'", 'id' => 'room')
      expect(attrs(%(<pushStream subtitle="x id='combat'"/>))).not_to have_key('id')
    end

    it 'reads only the start tag of a paired segment, not its content' do
      expect(attrs(%(<compass><dir value="n"/></compass>))).to eq({})
      expect(attrs(%(<prompt time="1727">x="y"&gt;</prompt>))).to eq('time' => '1727')
    end

    it 'accepts any run of spaces or tabs between attributes' do
      expect(attrs(%(<indicator  id='IconSTUNNED'\tvisible='y'/>))).to eq('id' => 'IconSTUNNED', 'visible' => 'y')
    end

    it 'does not decode entities' do
      expect(attrs(%(<d cmd='say &lt;hi&gt; &amp; &quot;bye&quot;'>))).to eq('cmd' => 'say &lt;hi&gt; &amp; &quot;bye&quot;')
    end

    it 'returns attributes in tag order' do
      expect(attrs(%(<progressBar text='health 75%' value='75' id='health'/>)).keys).to eq %w[text value id]
    end

    it 'returns nothing for a closing tag, plain text, an empty string or an empty tag' do
      ['</preset>', 'plain text', '', '<>', '< id="x">'].each { |tag| expect(attrs(tag)).to eq({}), tag }
    end

    it 'needs whitespace between the element name and the first attribute' do
      expect(attrs(%(<dcmd='go'>))).to eq({})
    end

    context 'with a malformed tag, stops reading at the first thing that is not an attribute' do
      {
        'an unquoted value'                  => %(<pushStream x=1 id="combat"/>),
        'a bare word'                        => %(<pushStream junk id="combat"/>),
        'a value with no closing quote'      => %(<pushStream id="combat/>),
        'mismatched quotes'                  => %(<pushStream id="combat'/>),
        'whitespace around ='                => %(<pushStream id = "combat"/>),
        'no whitespace before the attribute' => %(<pushStream x="1"id="combat"/>),
      }.each do |what, tag|
        it "(#{what})" do
          expect(attrs(tag)).not_to have_key('id')
        end
      end

      it 'keeps the attributes read before it' do
        expect(attrs(%(<pushStream id="combat" junk subtitle="x"/>))).to eq('id' => 'combat')
      end
    end

    it 'accepts the name characters XML uses: letters, digits, _ - . :' do
      expect(attrs(%(<x a_1="1" b-2="2" c.3="3" xml:lang="en"/>)).keys).to eq %w[a_1 b-2 c.3 xml:lang]
    end
  end
end
