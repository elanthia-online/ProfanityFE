# frozen_string_literal: true

require_relative '../../lib/server_text'

RSpec.describe ServerText do
  # A character from its code point (the source is ASCII).
  def char(code) = [code].pack('U')

  # Bytes as the socket hands them over (BINARY).
  def bytes(*codes) = codes.pack('C*')

  # normalize! on a copy of +text+ as raw bytes.
  def normalize(text) = described_class.normalize!(text.b)

  describe '.identity' do
    it 'writes % and each character outside ASCII as %XX per UTF-8 byte, and leaves the rest' do
      expect(described_class.identity("caf#{char(0x00E9)} 50% done")).to eq 'caf%C3%A9 50%25 done'
      expect(described_class.identity('combat')).to eq 'combat'
    end
  end

  # What a key ServerText.identity made looks like where the client shows it
  # (a custom timer with no label).
  describe '.readable' do
    {
      'caf%C3%A9' => 'caf?', 'Thurfel%E2%80%99s' => "Thurfel's", '50%25' => '50%',
      'plain' => 'plain', 'caf%C3' => 'caf?', '100%' => '100%'
    }.each do |key, shown|
      it "shows #{key.inspect} as #{shown.inspect}" do
        expect(described_class.readable(key)).to eq shown
      end
    end
  end

  describe '.normalize!' do
    [
      ['ASCII', 'A goblin dies.'.bytes, 'A goblin dies.'],
      ['a two-byte character', [0x53, 0x74, 0x72, 0x61, 0xC3, 0x9F, 0x65], 'Stra?e'],
      ['a three-byte character', [0x4B, 0x20, 0xE2, 0x84, 0xAA], 'K ?'],
      ['a four-byte character', [0x3A, 0xF0, 0x9F, 0x98, 0x80, 0x21], ':?!'],
      ['a lone Latin-1 byte', [0x53, 0x74, 0x72, 0x61, 0xDF, 0x65], 'Stra?e'],
      ['invalid bytes', [0xFF, 0xFE, 0x6F, 0x6B], '??ok'],
      ['a truncated character', [0x43, 0x61, 0x66, 0xC3], 'Caf?'],
      # scrub replaces each invalid sequence, which may be several bytes.
      ['a truncated three-byte character', [0x43, 0x61, 0x66, 0xE2, 0x82, 0x41], 'Caf?A'],
      ['NUL bytes', [0x6B, 0x00, 0x4B, 0x00], 'kK'],
      ['NUL bytes and characters outside ASCII', [0x63, 0x61, 0x66, 0xC3, 0xA9, 0x00, 0x21], 'caf?!'],
      # A BOM, then NULs between ASCII letters: used to reach the handlers
      # as U+FFFD and NULs.
      ['UTF-16 bytes', [0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00], '??hi']
    ].each do |what, codes, expected|
      it "makes a line with #{what} ASCII-only UTF-8" do
        result = described_class.normalize!(codes.pack('C*'))

        expect(result).to eq expected
        expect([result.encoding, result.valid_encoding?, result.ascii_only?]).to eq [Encoding::UTF_8, true, true]
      end
    end

    it 'changes the line it is given' do
      line = bytes(0x6B, 0x00, 0xC3, 0x9F)

      expect(described_class.normalize!(line)).to equal(line)
      expect(line).to eq 'k?'
    end

    describe 'in text' do
      {
        'curly quotes'                     => [[0x2018, 0x2019, 0x201C, 0x201D], %q(' ' " ")],
        'dashes'                           => [[0x2010, 0x2011, 0x2013, 0x2014, 0x2212], '- - - - -'],
        'an ellipsis and a no-break space' => [[0x2026, 0x00A0], '...  '],
        # A < goes in as an entity, which text has decoded.
        'arrows'                           => [[0x2192, 0x2190], '-> &lt;-']
      }.each do |what, (codes, expected)|
        it "puts ASCII look-alikes in place of #{what}" do
          text = codes.map { |code| char(code) }.join(' ')

          expect(normalize(text)).to eq expected
        end
      end

      # A script's banner and table borders (creaturebar.lic's help).
      it 'draws box drawing with - | = and +' do
        banner = [0x2554, 0x2550, 0x2550, 0x2557, 0x2551, 0x2500, 0x2502, 0x253C].map { |code| char(code) }.join

        expect(normalize(banner)).to eq '+==+|-|+'
      end

      it 'puts "?" in place of a character without a look-alike' do
        expect(normalize("smile #{char(0x1F600)} #{char(0x2605)}")).to eq 'smile ? ?'
      end
    end

    describe 'in a tag' do
      # effectmon.lic writes a curly apostrophe so the single-quoted label
      # still ends where it should.
      it "quotes an attribute value with the other quote when a look-alike is the value's quote" do
        line = "<arbProgress id='spell0' max='600' current='590' label='Thurfel#{char(0x2019)}s Ward' colors='1,2'/>"

        expect(normalize(line)).to eq %(<arbProgress id='spell0' max='600' current='590' label="Thurfel's Ward" colors='1,2'/>)
        expect(XmlTokenizer.attrs(normalize(line))['label']).to eq "Thurfel's Ward"
      end

      it 'keeps a double-quoted value double-quoted when it gains an apostrophe' do
        line = %(<d cmd="look at Thurfel#{char(0x2019)}s ward">x</d>)

        expect(normalize(line)).to eq %(<d cmd="look at Thurfel's ward">x</d>)
      end

      it 'keeps the quote and swaps the look-alikes when the value gains both quotes' do
        line = "<a label='#{char(0x201C)}Ha#{char(0x201D)} it#{char(0x2019)}s'/>"

        expect(normalize(line)).to eq %(<a label='"Ha" it"s'/>)
        expect(XmlTokenizer.attrs(normalize(line))['label']).to eq '"Ha" it"s'
      end

      # A value is used as sent and can't hold a <, but may hold a >.
      it 'writes arrows in a value without entities, and without a <' do
        line = "<a label='a #{char(0x2192)} b #{char(0x2190)} c'/>"

        expect(normalize(line)).to eq %(<a label='a -> b ? c'/>)
      end

      # A custom timer, a stream or a window is named by its id: ids that
      # differed must still differ.
      it 'writes an id losslessly: % and each character outside ASCII as %XX' do
        line = "<progressBar id='caf#{char(0x00E9)} 50%' text='caf#{char(0x00E9)}'/><progressBar id='50%' text='x'/>"

        expect(normalize(line)).to eq "<progressBar id='caf%C3%A9 50%25' text='caf?'/><progressBar id='50%25' text='x'/>"
        expect(normalize("<progressBar id='caf#{char(0x00E8)}'/>")).not_to eq normalize("<progressBar id='caf#{char(0x00E9)}'/>")
      end

      # An ASCII id that spells another id's %XX form must not become it.
      it 'keeps apart an id with characters outside ASCII and an ASCII id spelled like its %XX form' do
        expect(normalize("<a id='caf#{char(0x00E9)}'/>")).to eq "<a id='caf%C3%A9'/>"
        expect(normalize("<a id='caf%C3%A9'/>")).to eq "<a id='caf%25C3%25A9'/>"
      end

      # The same id must read the same on any line, all ASCII or not.
      it 'escapes % in an id on an all-ASCII line, as on any other line' do
        expect(normalize("<pushStream id='50%'/>plain")).to eq "<pushStream id='50%25'/>plain"
        expect(normalize("<pushStream id='50%'/>caf#{char(0x00E9)}")).to eq "<pushStream id='50%25'/>caf?"
        expect(normalize('You are 50% done.')).to eq 'You are 50% done.'
      end

      it 'keeps an id lossless on a line that gets ? throughout' do
        line = "<pushBold id='caf#{char(0x00E9)}' title='Bob's'/>Thurfel#{char(0x2019)}s Ward -> 5 min<popBold/>"

        expect(normalize(line)).to eq "<pushBold id='caf%C3%A9' title='Bob's'/>Thurfel?s Ward -> 5 min<popBold/>"
      end

      # A raw < in text (a script echoing it) and an arrow after it also
      # send a line to the ? fallback, with no tag gone wrong.
      it 'keeps the same key for an id on a line that falls back because of a raw < in text' do
        expect(normalize(%(<pushStream id="caf#{char(0x00E9)}"/>a < b #{char(0x2192)} c))).to eq '<pushStream id="caf%C3%A9"/>a < b ? c'
        expect(normalize(%(<pushStream id="caf#{char(0x00E9)}"/>plain))).to eq '<pushStream id="caf%C3%A9"/>plain'
      end

      it 'puts "?" in place of a character outside ASCII elsewhere in a tag' do
        expect(normalize("<a#{char(0x00E9)} x='1'/>text")).to eq "<a? x='1'/>text"
      end
    end

    # A look-alike quote or arrow next to a tag a script got wrong (a stray
    # quote, a < in a value) would end that tag elsewhere: such a line gets
    # "?" throughout instead.
    describe 'next to a tag with a stray quote' do
      it 'keeps an arrow in a value from ending the tag' do
        line = %(<d cmd="go #{char(0x2192)} gate" title='Bob's gate'>the gate</d>)

        expect(normalize(line)).to eq %(<d cmd="go ? gate" title='Bob's gate'>the gate</d>)
      end

      it 'keeps a curly quote in the text from closing the stray quote' do
        line = "<pushBold title='Bob's'/>Thurfel#{char(0x2019)}s Ward -> 5 min<popBold/>"

        expect(normalize(line)).to eq "<pushBold title='Bob's'/>Thurfel?s Ward -> 5 min<popBold/>"
      end

      # As an entity it can't start a tag that a later > would close.
      it 'writes a left arrow in text as an entity, even with a > after it' do
        expect(normalize("a #{char(0x2190)} b > c")).to eq 'a &lt;- b > c'
      end
    end

    # The game writes these whole, and their handlers use the content as sent.
    # Their content is used as sent, entities and all, and can't hold a <.
    it 'writes a left arrow in the content of a paired tag as "?"' do
      expect(normalize("<right>a #{char(0x2190)}sword</right>")).to eq '<right>a ?sword</right>'
    end

    it 'writes an arrow in the content of a paired tag as an ASCII arrow' do
      expect(normalize("<spell>Fire#{char(0x2192)}Ball</spell>")).to eq '<spell>Fire->Ball</spell>'
    end

    # Random lines: tags (some with a stray quote, a < or > in a value),
    # paired tags, and text with raw < and >, made of look-alike characters,
    # other characters outside ASCII, quotes, NULs and invalid bytes. Each
    # comes out ASCII and valid, without NULs, and with the same tags, read
    # paired and not, and the same text in each segment, as the line with "?"
    # for every character outside ASCII and every invalid byte, and no NULs.
    it 'keeps the tags of random lines' do
      rng = Random.new(20_261_119)
      specials = [0x2018, 0x2019, 0x201C, 0x201D, 0x2013, 0x2026, 0x00A0, 0x2192, 0x2190, 0x2550, 0x2551,
                  0x253C, 0x00DF, 0x212A, 0x1F600].map { |code| char(code).b }
      plain = ["a", 'b', "'", '"', '-', ' ', '<', '>', '&amp;', "\0", bytes(0xFF), bytes(0xC3)]
      piece = ->(n) { Array.new(rng.rand(0..n)) { (rng.rand < 0.45 ? specials : plain).sample(random: rng) }.join }
      segment = lambda do
        case rng.rand(5)
        when 0 then piece.call(8)
        when 1 then "<w a='#{piece.call(5)}' b=\"#{piece.call(5)}\"/>"
        when 2 then "<d cmd=\"#{piece.call(4)}\">#{piece.call(4)}</d>"
        when 3 then "<#{%w[spell right prompt].sample(random: rng)}>#{piece.call(5)}</#{%w[spell right prompt].sample(random: rng)}>"
        else "<pushBold/>#{piece.call(6)}<popBold/>"
        end
      end
      shape = lambda do |text|
        [true, false].map do |paired|
          XmlTokenizer.tokenize(text, paired: paired).map { |type, seg| type == :tag ? [seg[%r{\A</?\w*}], XmlTokenizer.attrs(seg).keys] : :text }
        end
      end
      # No look-alike is a letter: text that moved into a tag, or out of one,
      # moves its letters.
      letters = ->(text) { XmlTokenizer.tokenize(text, paired: false).map { |type, seg| [type, seg.delete('^ab')] } }
      3000.times do
        line = Array.new(rng.rand(1..5)) { segment.call }.join.b
        reference = line.dup.force_encoding(Encoding::UTF_8).scrub('?').delete("\0").gsub(ServerText::NON_ASCII, '?')

        result = described_class.normalize!(line.dup)

        expect([result.ascii_only?, result.valid_encoding?, result.include?("\0")]).to eq([true, true, false]), result.inspect
        expect(shape.call(result)).to eq(shape.call(reference)), "line #{line.inspect} became #{result.inspect}"
        expect(letters.call(result)).to eq(letters.call(reference)), "line #{line.inspect} became #{result.inspect}"
      end
    end
  end
end
