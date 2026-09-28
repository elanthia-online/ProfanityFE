# frozen_string_literal: true

# Tests where LNet chat shows up. Lich's lnet script sends LNet chat and LNet
# server messages on the thoughts stream; ProfanityFE moves them to an lnet
# window. The lines below are driven through the real server loop into real
# windows built from layout XML, and the assertions are on what each window
# shows.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'LNet chat routing' do
  let(:event_bus) { EventBus.new }
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }

  # Build the windows named in +windows+ (one text window per stream list,
  # each 3 rows high) and a processor that feeds them.
  def build(*windows)
    rows = windows.each_with_index.map do |streams, i|
      "<window class='text' top='#{i * 3}' left='0' height='3' width='60' value='#{streams}'/>"
    end
    LAYOUT['test'] = REXML::Document.new("<layout>#{rows.join}</layout>").root
    @wm = WindowManager.new
    @wm.load_layout('test')
    @wm.subscribe_to_events(event_bus)
    @processor = GameTextProcessor.new(
      window_mgr: @wm, shared_state: state, cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus
    )
  end

  # Feed raw server lines through GameTextProcessor#run, as the socket would.
  def receive_from_server(*lines)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    allow(IO).to receive(:select).and_return(nil)
    @processor.run(server)
  end

  def shown_in(stream)
    @wm.stream[stream].rows.reject(&:empty?)
  end

  let(:chat) { '[Private]-GSIV:Bob: "hello there"' }
  # A real LNet server message, from a Lich XML session log.
  let(:server_message) { '[server]: "no such channel or user"' }

  def receive_lnet(text)
    receive_from_server("<pushStream id=\"thoughts\"/>#{text}", '<popStream/>')
  end

  it 'shows LNet chat in the lnet window when the layout has one' do
    build('main', 'thoughts', 'lnet')

    receive_lnet(chat)

    expect(shown_in('lnet')).to eq [chat]
    expect(shown_in('thoughts')).to be_empty
  end

  it 'keeps a thoughts line in the thoughts window when its game code is not all letters' do
    build('main', 'thoughts', 'lnet')
    # '_' sits between 'Z' and 'a' in ASCII; LNet game codes are letters only.
    not_chat = '[Private]-G_S:Bob: "hi"'

    receive_lnet(not_chat)

    expect(shown_in('thoughts')).to eq [not_chat]
    expect(shown_in('lnet')).to be_empty
  end

  it 'shows LNet chat in the thoughts window when the layout has no lnet window' do
    build('main', 'thoughts')

    receive_lnet(chat)
    receive_lnet(server_message)

    expect(shown_in('thoughts')).to eq [chat, server_message]
  end

  it 'shows LNet chat in the main window when the layout has neither an lnet nor a thoughts window' do
    build('main')

    receive_lnet(chat)

    expect(shown_in('main')).to eq [chat]
  end
end
