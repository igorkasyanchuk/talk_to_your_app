# frozen_string_literal: true

require_relative "../../../tool"

module TalkToYourApp
  module Plugins
    module Db
      module Tools
        # Lists the table names in the wired database, so a client can discover
        # the schema before querying. Runs on the connection wired into the DB
        # plugin (`config.plugin :db, connection: :read`).
        class Tables < TalkToYourApp::Tool
          name        "db.tables"
          description "List the table names in the database."

          def call(_args, ctx)
            tables = ctx.connection { |conn| conn.tables.sort }
            json(tables: tables)
          rescue ActiveRecord::ActiveRecordError => e
            error("Could not list tables: #{e.message}")
          end
        end
      end
    end
  end
end
