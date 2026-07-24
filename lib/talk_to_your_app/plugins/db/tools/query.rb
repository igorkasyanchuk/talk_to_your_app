# frozen_string_literal: true

require_relative "../../../tool"
require_relative "../../../connection_registry"
require_relative "../../../renderers/html_table"

module TalkToYourApp
  module Plugins
    module Db
      module Tools
        # Runs a SQL query on the connection wired into the DB plugin and renders
        # the rows as JSON, plain text, or an HTML table. The query runs inside a
        # transaction with a per-query statement timeout, so a slow query cannot
        # poison the connection pool. On a :reading connection (the default)
        # writes are rejected by Rails' write prevention and the read-only DB
        # role — the gem does not parse SQL. On a :writing connection (opt-in)
        # writes execute.
        class Query < TalkToYourApp::Tool
          DEFAULT_TIMEOUT_MS = 30_000

          name        "db.query"
          description "Run a SQL query and return the rows."
          argument    :sql, :string, required: true, description: "A SQL statement."
          argument    :format, :string, enum: %w[json text html], default: "json",
            description: "Output format for the result rows."

          def call(args, ctx)
            format = args[:format] || "json"
            ms = timeout_ms(ctx)
            result = ctx.connection do |conn|
              conn.transaction do
                apply_statement_timeout(conn, ms)
                begin
                  conn.exec_query(args[:sql])
                ensure
                  clear_statement_timeout(conn)
                end
              end
            end
            render(result, format)
          rescue ActiveRecord::QueryCanceled, ActiveRecord::StatementTimeout => e
            error("Query exceeded the #{ms}ms statement timeout: #{e.message}")
          rescue ActiveRecord::ReadOnlyError => e
            # Rails' connected_to(role: :reading) blocks writes before they reach
            # the database; the read-only DB role is the backstop behind it.
            error("Write rejected: this connection is read-only. #{e.message}")
          rescue ActiveRecord::StatementInvalid => e
            error("Query failed: #{e.message}")
          end

          private

          # Resolved from the same connection name the query runs on
          # (ctx.connection_name), so the timeout and the query never come from
          # two different specs.
          def timeout_ms(ctx)
            spec = TalkToYourApp::ConnectionRegistry.fetch(ctx.connection_name)
            spec.statement_timeout || DEFAULT_TIMEOUT_MS
          end

          # The SQL that arms a per-query timeout for an adapter, or nil when the
          # adapter has no per-statement timeout. Pure (no connection) so it is
          # unit-testable without each database installed.
          #   Postgres -> transaction-local `statement_timeout` (unwound with the txn).
          #   MySQL    -> session `max_execution_time` (ms), bounding read-only SELECTs.
          #   SQLite / MariaDB / others -> none (documented in the README).
          def self.timeout_statement(adapter_name, ms)
            case adapter_name
            when /postgres/i      then "SET LOCAL statement_timeout = #{ms.to_i}"
            when /mysql|trilogy/i then "SET SESSION max_execution_time = #{ms.to_i}"
            end
          end

          def apply_statement_timeout(conn, ms)
            sql = self.class.timeout_statement(conn.adapter_name, ms)
            return unless sql

            conn.execute(sql)
          rescue ActiveRecord::StatementInvalid
            # The server does not support this timeout mechanism (e.g. MariaDB has
            # no `max_execution_time`). Run without a per-statement timeout rather
            # than failing every query; the read-only role still applies.
            nil
          end

          # Postgres' SET LOCAL unwinds with the transaction, but MySQL's session
          # variable persists on the pooled connection — clear it so a later
          # borrower of the reader connection is not capped by a stale value.
          def clear_statement_timeout(conn)
            return unless conn.adapter_name.match?(/mysql|trilogy/i)

            conn.execute("SET SESSION max_execution_time = 0")
          rescue ActiveRecord::StatementInvalid
            nil
          end

          def render(result, format)
            columns = result.columns
            max = TalkToYourApp::Plugins::Db.max_rows # nil means no cap
            truncated = max && result.rows.length > max
            rows = truncated ? result.rows.first(max) : result.rows

            case format
            when "html"
              html = Renderers::HtmlTable.render(columns, rows)
              text(truncated ? "#{html}<p>truncated to #{max} rows</p>" : html)
            when "text"
              body = render_text(columns, rows)
              text(truncated ? "#{body}\n(truncated to #{max} rows)" : body)
            else
              payload = { columns: columns, rows: rows }
              payload.merge!(truncated: true, max_rows: max) if truncated
              text(JSON.generate(payload))
            end
          end

          def render_text(columns, rows)
            display = rows.map { |row| row.map { |cell| cell.nil? ? "NULL" : cell.to_s } }
            widths = columns.each_index.map do |i|
              ([columns[i].to_s] + display.map { |r| r[i].to_s }).map(&:length).max
            end
            header = columns.each_with_index.map { |c, i| c.to_s.ljust(widths[i]) }.join("  ")
            body = display.map { |r| r.each_with_index.map { |c, i| c.ljust(widths[i]) }.join("  ") }
            ([header] + body).join("\n")
          end
        end
      end
    end
  end
end
