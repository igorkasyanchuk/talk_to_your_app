# frozen_string_literal: true

require "cgi"

module TalkToYourApp
  module Renderers
    # Minimal HTML table renderer — no ActionView dependency. Every value is
    # HTML-escaped via CGI.escape_html; the output is returned as a plain string
    # for an MCP text content block and is never marked html_safe. NULL cells
    # render as empty.
    module HtmlTable
      module_function

      def render(columns, rows)
        head = "<thead><tr>#{columns.map { |c| "<th>#{esc(c)}</th>" }.join}</tr></thead>"
        body = rows.map do |row|
          "<tr>#{row.map { |cell| "<td>#{cell.nil? ? "" : esc(cell)}</td>" }.join}</tr>"
        end.join
        "<table>#{head}<tbody>#{body}</tbody></table>"
      end

      def esc(value)
        CGI.escape_html(value.to_s)
      end
    end
  end
end
