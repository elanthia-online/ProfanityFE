# frozen_string_literal: true

require 'stringio'
require_relative '../../lib/selection_manager'
require_relative '../../lib/profanity_settings'

# The copy_to_clipboard file fallback. It used to be a fixed, world-shared
# /tmp/profanity_selection.txt written 0644 through any symlink, so other
# local users could read the copied text or plant a symlink that made the
# victim overwrite their own files. It now lives in the per-user
# ~/.profanity/ (HOME is sandboxed by spec_helper).
RSpec.describe 'SelectionManager.copy_to_clipboard file fallback' do
  let(:tty) { StringIO.new }
  let(:selection_file) { ProfanitySettings.file('selection.txt') }
  let(:shared_tmp_file) { '/tmp/profanity_selection.txt' }

  around do |example|
    saved_env = ENV.to_h
    saved_umask = File.umask
    example.run
  ensure
    File.umask(saved_umask)
    ENV.replace(saved_env)
    FileUtils.rm_f(selection_file)
  end

  before do
    %w[STY TMUX WAYLAND_DISPLAY DISPLAY].each { |key| ENV.delete(key) }
    stub_const('RbConfig::CONFIG', RbConfig::CONFIG.merge('host_os' => 'linux-gnu'))
    allow(File).to receive(:open).and_call_original
    allow(File).to receive(:open).with('/dev/tty', 'w').and_yield(tty)
    # Never touch the real shared /tmp from the suite.
    allow(File).to receive(:write).and_call_original
    allow(File).to receive(:write).with(shared_tmp_file, any_args)
    allow(File).to receive(:open).with(shared_tmp_file, any_args)
  end

  it 'writes the selection to ~/.profanity/selection.txt, readable only by the owner' do
    File.umask(0o000)

    SelectionManager.copy_to_clipboard('secret')

    expect(File.read(selection_file)).to eq('secret')
    expect(File.stat(selection_file).mode & 0o777).to eq(0o600)
    expect(File).not_to have_received(:write).with(shared_tmp_file, any_args)
    expect(File).not_to have_received(:open).with(shared_tmp_file, any_args)
  end

  it 'makes an existing selection file readable only by the owner' do
    File.write(selection_file, 'an older, longer selection')
    File.chmod(0o644, selection_file)

    SelectionManager.copy_to_clipboard('secret')

    expect(File.read(selection_file)).to eq('secret')
    expect(File.stat(selection_file).mode & 0o777).to eq(0o600)
  end

  it 'refuses to write through a symlink planted at the selection file' do
    Dir.mktmpdir('victim') do |dir|
      victim = File.join(dir, 'important.txt')
      File.write(victim, "victim data\n")
      File.symlink(victim, selection_file)

      SelectionManager.copy_to_clipboard('secret')

      expect(File.read(victim)).to eq("victim data\n")
      expect(File.symlink?(selection_file)).to be(true)
      expect(tty.string).to eq("\e]52;c;#{['secret'].pack('m0')}\a")
    end
  end
end
