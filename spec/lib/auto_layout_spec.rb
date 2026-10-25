# frozen_string_literal: true

require_relative '../../lib/auto_layout'
require_relative '../../lib/cli_options'

RSpec.describe AutoLayout do
  let(:layouts) { %w[default mobile wide].to_h { |id| [id, true] } }

  it 'selects the three tiers at their exact width boundaries' do
    { 40 => 'mobile', 89 => 'mobile', 90 => 'default', 159 => 'default', 160 => 'wide', 240 => 'wide' }.each do |cols, id|
      expect(described_class.new.choose(layouts, cols)).to eq id
    end
  end

  it 'falls back with unmodified upstream templates and missing optional tiers' do
    expect(described_class.new.choose({ 'default' => true }, 40)).to eq 'default'
    expect(described_class.new.choose({ 'default' => true }, 240)).to eq 'default'
    expect(described_class.new.choose({ 'custom' => true }, 240)).to eq 'custom'
    expect(described_class.new.choose({}, 240)).to be_nil
  end

  it 'supports the existing layout option names and custom thresholds' do
    options = CliOptions.parse(%w[--narrow-layout=normal --wide-layout=large --mobile-layout=phone
                                  --wide-layout-cols=180 --mobile-layout-cols=70])
    policy = described_class.new(options)
    available = %w[normal large phone].to_h { |id| [id, true] }
    expect(policy.choose(available, 69)).to eq 'phone'
    expect(policy.choose(available, 70)).to eq 'normal'
    expect(policy.choose(available, 180)).to eq 'large'
  end

  it 'can start disabled and resume automatic selection' do
    policy = described_class.new(CliOptions.parse(['--no-auto-layout']))
    expect(policy.choose(layouts, 240)).to eq 'default'
    policy.enabled = true
    expect(policy.choose(layouts, 240)).to eq 'wide'
  end

  it 'rejects non-positive and nonnumeric thresholds' do
    %w[--wide-layout-cols=0 --mobile-layout-cols=-1 --wide-layout-cols=abc].each do |flag|
      expect { CliOptions.parse([flag]) }.to raise_error(OptionParser::InvalidArgument)
    end
  end
end
