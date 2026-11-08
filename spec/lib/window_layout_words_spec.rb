# frozen_string_literal: true

# In WindowLayout.evaluate the names "lines" and "cols" stand for the
# terminal's size. They used to be replaced as text, anywhere, before the
# whitespace was dropped, so on a 24 x 80 terminal "2lines" and "2 lines"
# became 224 and "linescols" 2480, with no warning. Now they are names, and
# a number or a name where an operator is missing is an expression that
# can't be worked out (0, and a settings warning that names it as written).

require 'rexml/document'
require_relative '../../lib/window_layout'

RSpec.describe WindowLayout do
  before do
    allow(Curses).to receive(:lines).and_return(24)
    allow(Curses).to receive(:cols).and_return(80)
  end

  describe '.evaluate' do
    {
      'lines' => 24, 'cols' => 80, 'lines-2' => 22, 'cols/3+1' => 27, 'lines - 1' => 23,
      '(lines)' => 24, 'min(lines,cols)' => 24, 'max(1, min(cols/3, 40))' => 26, '2*lines' => 48,
      ' lines * 2 ' => 48, '3 3' => 33, '2(3)' => 2, '10)' => 10, '(2)3' => 2, 'min(1, 2)3' => 1,
      '(lines)2' => 24
    }.each do |expression, value|
      it "puts the terminal's size in for #{expression.inspect}" do
        expect(described_class.evaluate(expression)).to eq value
        expect(SettingsWarnings.take).to eq []
      end
    end

    %w[linescols colscols colslines xlines lines_2 LINES].each do |expression|
      it "does not put a number in for part of a word, in #{expression.inspect}" do
        expect { expect(described_class.evaluate(expression)).to eq 0 }
          .to warn_in_settings("Invalid layout expression (unsafe characters): #{expression}")
      end
    end

    # Each of these used to give a number made of the size and the digits
    # or size next to it (224, 242, 2480 ...).
    { '2lines' => 'lines', '2 lines' => 'lines', 'lines2' => '2', 'lines 2' => '2', 'lines cols' => 'cols',
      'cols  lines' => 'lines', '(lines)(cols)' => 'cols', '2(lines)' => 'lines',
      'lines(2)' => '(', 'lines (2)' => '(' }.each do |expression, extra|
      it "refuses #{expression.inspect}, where an operator is missing" do
        expect { expect(described_class.evaluate(expression)).to eq 0 }
          .to warn_in_settings("Layout expression error: #{extra} after the end of the expression " \
                               "(missing an operator?) in '#{expression}'")
      end
    end
  end

  # The bundled layouts must keep working with lines and cols as names: no
  # expression in them may become one that can't be worked out.
  describe 'the bundled templates' do
    expressions = Dir[File.expand_path('../../templates/*.xml', __dir__)].flat_map do |template|
      REXML::Document.new(File.read(template)).get_elements('//window').flat_map do |window|
        %w[height width top left].filter_map { |name| window.attributes[name] }
      end
    end.uniq

    it 'has layout expressions to check' do
      expect(expressions.size).to be > 50
    end

    it 'evaluates every layout expression without a warning, at small and large sizes' do
      [[24, 80], [63, 213]].each do |lines, cols|
        allow(Curses).to receive_messages(lines: lines, cols: cols)

        expressions.each { |expression| described_class.evaluate(expression) }

        expect(SettingsWarnings.take).to eq([]), "at #{lines} x #{cols}"
      end
    end
  end
end
