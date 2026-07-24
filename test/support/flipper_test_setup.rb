# frozen_string_literal: true

require "flipper"
require "flipper/adapters/active_record"

module TalkToYourApp
  # Configures Flipper to use its ActiveRecord adapter against the dummy app's
  # database, creating the flipper tables once. Proves the plugin persists state
  # through the (writer) connection rather than an in-memory stub.
  module FlipperTestSetup
    module_function

    def install!
      return if @installed

      create_tables
      ::Flipper.configure do |config|
        config.adapter { ::Flipper::Adapters::ActiveRecord.new }
      end
      @installed = true
    end

    def reset!
      install!
      ::Flipper.instance = nil # drop memoized DSL so the adapter is rebuilt
      ActiveRecord::Base.connection.execute("DELETE FROM flipper_gates")
      ActiveRecord::Base.connection.execute("DELETE FROM flipper_features")
    end

    def create_tables
      conn = ActiveRecord::Base.connection
      return if conn.table_exists?(:flipper_features)

      ActiveRecord::Schema.define do
        create_table :flipper_features do |t|
          t.string :key, null: false
          t.timestamps null: false
        end
        add_index :flipper_features, :key, unique: true

        create_table :flipper_gates do |t|
          t.string :feature_key, null: false
          t.string :key, null: false
          t.text :value
          t.timestamps null: false
        end
        add_index :flipper_gates, %i[feature_key key value], unique: true, length: { value: 255 }
      end
    end
  end
end
