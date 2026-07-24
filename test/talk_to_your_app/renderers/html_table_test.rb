# frozen_string_literal: true

require "test_helper"

class TalkToYourApp::Renderers::HtmlTableTest < TalkToYourApp::TestCase
  Renderer = TalkToYourApp::Renderers::HtmlTable

  def test_renders_table_with_headers_and_rows
    html = Renderer.render(["one"], [[1]])
    assert_equal "<table><thead><tr><th>one</th></tr></thead><tbody><tr><td>1</td></tr></tbody></table>", html
  end

  def test_escapes_html_in_cells
    html = Renderer.render(["c"], [["<script>alert(1)</script>"]])
    assert_includes html, "&lt;script&gt;alert(1)&lt;/script&gt;"
    refute_includes html, "<script>"
  end

  def test_null_cell_renders_empty
    html = Renderer.render(["c"], [[nil]])
    assert_includes html, "<td></td>"
  end

  def test_empty_result_renders_empty_tbody
    html = Renderer.render(["c"], [])
    assert_includes html, "<tbody></tbody>"
  end
end
