# frozen_string_literal: true

# Feedback.colors and Feedback.write on their own. What the user sees of
# them through the real Application is in feedback_output_spec.rb.

require_relative '../../lib/feedback'

RSpec.describe Feedback do
  # A window that records what it is given.
  let(:window) do
    Class.new do
      attr_reader :calls

      def initialize = @calls = []
      def add_string(text, colors) = calls << [text, colors]
    end.new
  end

  it 'colors the whole line, including an empty one' do
    expect(Feedback.colors('hello')).to eq [{ start: 0, end: 5, fg: FEEDBACK_COLOR, bg: nil, ul: nil }]
    expect(Feedback.colors('', 'abcdef')).to eq [{ start: 0, end: 0, fg: 'abcdef', bg: nil, ul: nil }]
  end

  it 'counts characters, not bytes, so a non-ASCII line is colored to its end' do
    expect(Feedback.colors('* café').first[:end]).to eq 6
  end

  it 'writes nothing and says so for a nil window' do
    expect(Feedback.write(nil, 'x', banner: true)).to be false
  end

  it 'keeps the banner rows in the feedback color when the lines have another' do
    expect(Feedback.write(window, 'a', 'b', fg: 'abcdef', banner: true)).to be true
    expect(window.calls.map { |text, colors| [text, colors.first[:fg]] })
      .to eq [['* ', FEEDBACK_COLOR], %w[a abcdef], %w[b abcdef], ['* ', FEEDBACK_COLOR]]
  end

  it 'writes just the two banner rows when there are no lines' do
    Feedback.write(window, banner: true)
    expect(window.calls.map(&:first)).to eq ['* ', '* ']
  end

  it 'gives each line its own color list, so a window changing one cannot recolor another' do
    Feedback.write(window, 'a', 'b', banner: true)
    lists = window.calls.map(&:last)
    expect(lists.map(&:object_id).uniq.size).to eq 4
  end
end
