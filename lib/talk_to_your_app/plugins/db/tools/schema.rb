# frozen_string_literal: true

require_relative "../../../tool"

module TalkToYourApp
  module Plugins
    module Db
      module Tools
        # Describes a single table from the live read-only database: its columns,
        # primary key, indexes, and foreign keys. Lets a client learn a table's
        # shape without a schema dump.
        class Schema < TalkToYourApp::Tool
          name        "db.schema"
          description "Describe a table: columns, primary key, indexes, and foreign keys."
          argument    :table, :string, required: true, description: "Table name (see db.tables)."

          def call(args, ctx)
            table = args[:table].to_s
            ctx.connection do |conn|
              unless conn.tables.include?(table)
                next error("Unknown table #{table.inspect}. Use db.tables to list available tables.")
              end

              json(describe(conn, table))
            end
          rescue ActiveRecord::ActiveRecordError => e
            error("Could not describe #{args[:table].inspect}: #{e.message}")
          end

          private

          def describe(conn, table)
            {
              table: table,
              primary_key: conn.primary_key(table),
              columns: conn.columns(table).map do |col|
                { name: col.name, type: col.sql_type, null: col.null, default: col.default }
              end,
              indexes: conn.indexes(table).map do |idx|
                { name: idx.name, columns: idx.columns, unique: idx.unique }
              end,
              foreign_keys: foreign_keys(conn, table),
            }
          end

          def foreign_keys(conn, table)
            return [] unless conn.supports_foreign_keys?

            conn.foreign_keys(table).map do |fk|
              { column: fk.column, references_table: fk.to_table, references_column: fk.primary_key }
            end
          end
        end
      end
    end
  end
end
