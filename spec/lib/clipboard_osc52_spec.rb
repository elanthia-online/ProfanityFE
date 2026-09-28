# frozen_string_literal: true

require 'stringio'
require_relative '../../lib/selection_manager'

# What the outer terminal receives from copy_to_clipboard's OSC 52 escape
# when Profanity runs inside a multiplexer. Each OSC 52 sequence *replaces*
# the terminal clipboard, so the text must arrive as exactly one sequence.
RSpec.describe 'SelectionManager.copy_to_clipboard OSC 52 through a multiplexer' do
  let(:tty) { StringIO.new }
  # 1500 characters => 2000 bytes of base64, several GNU screen chunks.
  let(:long_text) { (1..1500).map { |i| (i % 10).to_s }.join }

  # GNU screen passes the body of each DCS (ESC P ... ESC \) to the outer
  # terminal verbatim. Anything outside a DCS would be parsed by screen
  # itself, so the whole output must be DCS strings.
  def through_screen(bytes)
    bodies = bytes.scan(/\eP(.*?)\e\\/m).flatten
    expect(bodies.map { |b| "\eP#{b}\e\\" }.join).to eq(bytes)
    [bodies.join, bodies]
  end

  # tmux forwards the body of "ESC P tmux; ... ESC \" with doubled ESCs undone.
  def through_tmux(bytes)
    bodies = bytes.scan(/\ePtmux;(.*?)\e\\/m).flatten
    expect(bodies.map { |b| "\ePtmux;#{b}\e\\" }.join).to eq(bytes)
    bodies.join.gsub("\e\e", "\e")
  end

  def osc52_payloads(terminal_bytes)
    terminal_bytes.scan(/\e\]52;c;([A-Za-z0-9+\/=]*)(?:\a|\e\\)/).flatten.map { |b64| b64.unpack1('m0') }
  end

  around do |example|
    saved_env = ENV.to_h
    example.run
  ensure
    ENV.replace(saved_env)
  end

  before do
    %w[STY TMUX WAYLAND_DISPLAY DISPLAY].each { |key| ENV.delete(key) }
    stub_const('RbConfig::CONFIG', RbConfig::CONFIG.merge('host_os' => 'linux-gnu'))
    allow(File).to receive(:open).and_call_original
    allow(File).to receive(:open).with('/dev/tty', 'w').and_yield(tty)
    allow(File).to receive(:write)
  end

  context 'under GNU screen' do
    before { ENV['STY'] = '12345.pts-0.host' }

    it 'delivers a long selection as one OSC 52 sequence split across DCS strings' do
      SelectionManager.copy_to_clipboard(long_text)

      terminal, bodies = through_screen(tty.string)
      payloads = osc52_payloads(terminal)
      expect(payloads.map(&:length)).to eq([long_text.length])
      expect(payloads).to eq([long_text])
      expect(bodies.size).to be > 1
      # Screen drops DCS strings longer than its buffer (~768 bytes).
      expect(bodies.map(&:bytesize).max).to be <= 512
    end

    it 'delivers a short selection as one OSC 52 sequence' do
      SelectionManager.copy_to_clipboard('hello')

      terminal, = through_screen(tty.string)
      expect(osc52_payloads(terminal)).to eq(['hello'])
    end
  end

  context 'under tmux' do
    before { ENV['TMUX'] = '/tmp/tmux-1000/default,1234,0' }

    it 'delivers a long selection as one OSC 52 sequence in one passthrough' do
      SelectionManager.copy_to_clipboard(long_text)

      expect(osc52_payloads(through_tmux(tty.string))).to eq([long_text])
    end
  end
end
