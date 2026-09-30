# frozen_string_literal: true

# Tests CursesRenderer.outside_lock: a block that may block runs only
# when the calling thread does not hold the render lock.

require 'monitor'

RSpec.describe 'CursesRenderer.outside_lock' do
  # spec_helper stubs CursesRenderer; load the real one into a wrapper
  # module so the rest of the suite keeps the stub.
  let(:renderer) do
    Module.new.tap { |wrapper| load(File.expand_path('../../lib/curses_renderer.rb', __dir__), wrapper) }::CursesRenderer
  end
  let(:events) { [] }

  # Whether this thread holds the render lock: another thread (the server
  # thread) can't take it. The other thread gets 5 seconds, so a busy
  # machine doesn't read as a held lock.
  def lock_held? = !Thread.new { renderer.synchronize { true } }.join(5)

  it 'runs the block at once when the lock is not held' do
    result = renderer.outside_lock { events << [:ran, lock_held?]; :value }

    expect(events).to eq [[:ran, false]]
    expect(result).to eq :value
  end

  it 'runs the block after the outermost hold releases the lock, in order' do
    renderer.synchronize do
      renderer.outside_lock { events << [:first, lock_held?] }
      renderer.render do
        renderer.outside_lock { events << [:second, lock_held?] }
      end
      events << :nested_hold_released
      renderer.doupdate
      events << :end_of_outer_hold
    end

    expect(events).to eq [:nested_hold_released, :end_of_outer_hold, [:first, false], [:second, false]]
  end

  it 'still runs the deferred block when the held block raises' do
    expect do
      renderer.synchronize do
        renderer.outside_lock { events << [:ran, lock_held?] }
        raise 'boom'
      end
    end.to raise_error('boom')

    expect(events).to eq [[:ran, false]]
  end

  it "does not defer another thread's block while this thread holds the lock" do
    renderer.synchronize do
      Thread.new { renderer.outside_lock { events << :other_thread } }.join
      events << :still_holding
    end

    expect(events).to eq %i[other_thread still_holding]
  end
end
