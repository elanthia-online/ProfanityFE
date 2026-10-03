# frozen_string_literal: true

# Tests LinkExtractor.extract_cmd for GS <a exist/noun>, GS coord links
# and DR <d cmd> tags. Where links are found in a line is the tag parser's job (see
# spec/lib/room_carriers_spec.rb and link_commands_spec.rb).

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

    # ---- GS coord links: the game's command table ----

    it 'gives a coord link no command (false) when no table arrived' do
      tag = '<a exist="-11223064" coord="2524,1864" noun="north">'
      expect(described_class.extract_cmd(tag)).to be false
    end

    it "gives a coord link its coord's command from the table" do
      table = CoordCommands.new.tap do |commands|
        commands.start
        commands.add(coord: '2524,1864', command: 'go @')
        commands.finish
      end
      tag = '<a exist="-11223064" coord="2524,1864" noun="north">'
      expect(described_class.extract_cmd(tag, coord_commands: table)).to eq 'go north'
      expect(described_class.extract_cmd('<a exist="1" coord="2524,1865" noun="x">', coord_commands: table)).to be false
    end

    it 'reads coord only from an attribute with exactly that name, and not when it is empty' do
      {
        '<a exist="1" coord="2524,1864" noun="north">'  => false,
        "<a coord='2524,1864'>"                         => false,
        '<a exist="1" xcoord="2524,1864" noun="north">' => 'look #1',
        '<a exist="1" coord="" noun="north">'           => 'look #1',
        '<a exist="1" coord="" noun="">'                => '_drag #1',
        "<a exist='1' coord='2524,1864' cmd='go'>"      => 'go'
      }.each do |tag, cmd|
        expect(described_class.extract_cmd(tag)).to eq(cmd), tag
      end
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
end
