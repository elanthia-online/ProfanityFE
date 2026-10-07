# frozen_string_literal: true

# Tests SharedState thread-safe accessors: prompt, room_title, time
# offset, blue_links, atomic update_prompt/consume_prompt!, and
# terminal title generation with dedup.

require 'tempfile'
require_relative '../../lib/shared_state'

RSpec.describe SharedState do
  subject(:state) { described_class.new }

  describe '#initialize' do
    it('need_prompt defaults false') { expect(state.need_prompt).to be false }
    it('prompt_text defaults ">"') { expect(state.prompt_text).to eq '>' }
    it('room_title defaults ""') { expect(state.room_title).to eq '' }
    it('skip_server_time_offset defaults false') { expect(state.skip_server_time_offset).to be false }
    it('blue_links defaults false') { expect(state.blue_links).to be false }
    it('char_name defaults nil') { expect(state.char_name).to be_nil }
    it('no_status defaults false') { expect(state.no_status).to be false }
    it('room_window_only defaults false') { expect(state.room_window_only).to be false }
  end

  describe '#update_prompt' do
    context 'when prompt text changes' do
      it 'returns true' do
        expect(state.update_prompt('H>')).to be true
      end

      it 'updates prompt_text' do
        state.update_prompt('H>')
        expect(state.prompt_text).to eq 'H>'
      end

      it 'clears need_prompt' do
        state.need_prompt = true
        state.update_prompt('H>')
        expect(state.need_prompt).to be false
      end
    end

    context 'when prompt text is unchanged' do
      before { state.update_prompt('H>') }

      it 'returns false' do
        expect(state.update_prompt('H>')).to be false
      end

      it 'sets need_prompt to true' do
        state.update_prompt('H>')
        expect(state.need_prompt).to be true
      end
    end

    # Adversarial
    it 'handles empty string prompt' do
      expect(state.update_prompt('')).to be true
      expect(state.prompt_text).to eq ''
    end

    it 'handles very long prompt' do
      long_prompt = 'X' * 1000 + '>'
      state.update_prompt(long_prompt)
      expect(state.prompt_text).to eq long_prompt
    end

    it 'handles prompt with special characters' do
      state.update_prompt("H\t>")
      expect(state.prompt_text).to eq "H\t>"
    end

    it 'treats whitespace-different prompts as changed' do
      state.update_prompt('H>')
      expect(state.update_prompt('H >')).to be true
    end
  end

  describe '#consume_prompt!' do
    it 'returns true and clears when pending' do
      state.need_prompt = true
      expect(state.consume_prompt!).to be true
      expect(state.need_prompt).to be false
    end

    it 'returns false when not pending' do
      expect(state.consume_prompt!).to be false
    end

    it 'is idempotent (second call returns false)' do
      state.need_prompt = true
      state.consume_prompt!
      expect(state.consume_prompt!).to be false
    end
  end

  describe '#update_terminal_title' do
    let(:term) { 'xterm-256color' }
    let(:tmux) { nil }
    let(:sty) { nil }

    # Every example runs with file descriptor 1 redirected to a file, so
    # title bytes never reach the rspec output and tty_bytes sees whatever
    # was written, whether by this process or by a child that inherited it.
    around do |example|
      original_env = ENV.to_h.slice('TERM', 'TMUX', 'STY')
      ENV['TERM'] = term
      ENV['TMUX'] = tmux
      ENV['STY'] = sty
      saved_stdout = $stdout.dup
      Tempfile.create('tty') do |tty|
        @tty = tty
        $stdout.reopen(tty)
        example.run
      ensure
        $stdout.reopen(saved_stdout)
      end
    ensure
      saved_stdout&.close
      %w[TERM TMUX STY].each { |key| ENV[key] = original_env[key] }
    end

    # Run the title update and return the bytes it wrote to the terminal.
    def tty_bytes
      state.update_terminal_title
      $stdout.flush
      File.read(@tty.path, encoding: Encoding::UTF_8)
    end

    before do
      state.char_name = 'Mahtra'
      state.no_status = false
      allow(Process).to receive(:setproctitle)
    end

    it 'writes an OSC 0 sequence carrying the full title' do
      state.prompt_text = 'H>'
      state.room_title = 'Town Square'
      expect(tty_bytes).to eq "\e]0;Mahtra [H:Town Square]\a"
    end

    it 'emits no screen/tmux window-name sequence outside screen/tmux' do
      state.prompt_text = 'H>'
      expect(tty_bytes).to eq "\e]0;Mahtra [H]\a"
    end

    context 'when TERM says screen but no screen/tmux session is running' do
      let(:term) { 'screen-256color' }

      it 'emits no window-name sequence for the outer terminal to print' do
        state.prompt_text = 'H>'
        expect(tty_bytes).to eq "\e]0;Mahtra [H]\a"
      end
    end

    context 'when running inside screen' do
      let(:term) { 'screen.xterm-256color' }
      let(:sty) { '12345.pts-0.host' }

      it 'writes the real ESC k name ESC \\ window-name sequence' do
        state.prompt_text = 'H>'
        expect(tty_bytes).to eq "\e]0;Mahtra [H]\a\ekMahtra\e\\"
      end
    end

    context 'when running inside tmux' do
      let(:term) { 'tmux-256color' }
      let(:tmux) { '/tmp/tmux-1000/default,1234,0' }

      it 'writes the real ESC k name ESC \\ window-name sequence' do
        state.prompt_text = 'H>'
        expect(tty_bytes).to end_with "\ekMahtra\e\\"
      end
    end

    context 'when the title text contains terminal control characters' do
      let(:term) { 'screen' }
      let(:sty) { '12345.pts-0.host' }

      it 'strips them so the title cannot end or inject a sequence' do
        state.char_name = "Mah\e\\\etra\a"
        state.prompt_text = "H\u009c>"
        state.room_title = "Room\e]0;pwned\a\x01\n\\"
        expect(tty_bytes).to eq "\e]0;Mahtra [H:Room]0;pwned]\a\ekMahtra\e\\"
      end
    end

    it 'writes from Ruby without spawning a subprocess' do
      allow(state).to receive(:system)
      allow(Process).to receive(:spawn)
      allow(IO).to receive(:popen)
      state.prompt_text = 'H>'
      expect(tty_bytes).to start_with "\e]0;"
      expect(state).not_to have_received(:system)
      expect(Process).not_to have_received(:spawn)
      expect(IO).not_to have_received(:popen)
    end

    it 'sets the process title to the same title' do
      state.prompt_text = 'H>'
      state.room_title = 'Town Square'
      state.update_terminal_title
      expect(Process).to have_received(:setproctitle).with('Mahtra [H:Town Square]')
    end

    it 'skips when char_name is nil' do
      state.char_name = nil
      state.update_terminal_title
      expect(Process).not_to have_received(:setproctitle)
    end

    it 'skips when no_status is true' do
      state.no_status = true
      state.update_terminal_title
      expect(Process).not_to have_received(:setproctitle)
    end

    it 'deduplicates identical titles' do
      state.prompt_text = 'H>'
      state.room_title = 'Same'
      state.update_terminal_title
      state.update_terminal_title
      # setproctitle should be called only once (dedup)
      expect(Process).to have_received(:setproctitle).once
    end

    it 'updates when prompt changes' do
      state.prompt_text = 'H>'
      state.update_terminal_title
      state.prompt_text = 'S>'
      state.update_terminal_title
      expect(Process).to have_received(:setproctitle).twice
    end

    it 'follows a prompt recorded by update_prompt' do
      state.update_prompt('H>')
      expect(tty_bytes).to eq "\e]0;Mahtra [H]\a"
    end

    it 'is not rewritten when update_prompt sees the same prompt again' do
      state.update_prompt('H>')
      state.update_terminal_title
      state.update_prompt('H>')
      state.update_terminal_title
      expect(Process).to have_received(:setproctitle).once
    end

    it 'drops the room from the title when the room title is cleared' do
      state.prompt_text = 'H>'
      state.room_title = 'Town Square'
      state.update_terminal_title
      state.room_title = ''
      expect(tty_bytes).to eq "\e]0;Mahtra [H:Town Square]\a\e]0;Mahtra [H]\a"
    end

    it 'shows only the room when the prompt is empty' do
      state.prompt_text = ''
      state.room_title = 'Room'
      expect(tty_bytes).to eq "\e]0;Mahtra [Room]\a"
    end

    it 'keeps brackets, parentheses, ampersands and quotes in the room title' do
      state.prompt_text = '>'
      state.room_title = "Room [with] (parens) & 'quotes'"
      expect(tty_bytes).to eq "\e]0;Mahtra [Room [with] (parens) & 'quotes']\a"
    end
  end
end
