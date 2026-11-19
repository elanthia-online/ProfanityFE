# frozen_string_literal: true

require_relative '../../lib/ruby_advisory'

RSpec.describe RubyAdvisory do
  describe '.warning' do
    # Ruby 3.3.13 and earlier, 3.4.0 to 3.4.12 and 4.0.0 to 4.0.9 have the
    # bugs (ruby-lang.org advisory of 2026-11-18); 3.2 and earlier get no fix.
    {
      '4.0.0' => '4.0.10', '4.0.5' => '4.0.10', '4.0.9' => '4.0.10',
      '3.4.0' => '3.4.13', '3.4.12' => '3.4.13',
      '3.3.0' => '3.3.14', '3.3.13' => '3.3.14',
      '3.2.9' => '4.0.10', '2.7.8' => '4.0.10'
    }.each do |version, fix|
      it "warns on Ruby #{version} and names #{fix} as the fix" do
        expect(described_class.warning(version: version, engine: 'ruby'))
          .to eq ["Ruby #{version} has security bugs in regular expressions and strings, fixed in Ruby #{fix}. " \
                  'Please upgrade Ruby.',
                  "Details: #{described_class::URL}"]
      end
    end

    %w[4.0.10 4.0.11 4.0.100 4.1.0 5.0.0 3.4.13 3.4.20 3.3.14 3.3.15].each do |version|
      it "does not warn on Ruby #{version}" do
        expect(described_class.warning(version: version, engine: 'ruby')).to be_nil
      end
    end

    # A string comparison would put "4.0.10" before "4.0.9", and the
    # fixed release would be taken for an affected one.
    it 'compares versions as numbers, not strings' do
      expect(described_class.warning(version: '4.0.10', engine: 'ruby')).to be_nil
      expect(described_class.warning(version: '4.0.9', engine: 'ruby')).not_to be_nil
    end

    %w[jruby truffleruby].each do |engine|
      it "does not warn on #{engine}, whose regular expressions are not CRuby's" do
        expect(described_class.warning(version: '3.4.0', engine: engine)).to be_nil
      end
    end

    it 'does not warn on a version it cannot read' do
      expect(described_class.warning(version: 'not a version', engine: 'ruby')).to be_nil
    end

    it 'checks the running Ruby by default' do
      expect(described_class.warning).to eq described_class.warning(version: RUBY_VERSION, engine: RUBY_ENGINE)
    end
  end
end
