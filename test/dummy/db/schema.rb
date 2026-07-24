# frozen_string_literal: true

# Loaded into the database by the test helper (in-memory, for tests) and by
# `bin/rails db:schema:load` / `db:prepare` (for the local development server).
ActiveRecord::Schema.define(version: 5) do
  create_table :widgets, force: true do |t|
    t.string :name
    t.integer :quantity
    t.timestamps
  end

  # Append-only audit trail written by the MCP audit subscriber (see
  # config/initializers/talk_to_your_app.rb) — one row per tool call.
  create_table :activities, force: true do |t|
    t.string :principal
    t.string :ip
    t.string :plugin
    t.string :tool
    t.text :params
    t.string :outcome
    t.float :duration_ms
    t.timestamps
  end

  create_table :users, force: true do |t|
    t.string :name, null: false
    t.string :email
    t.string :api_token
    t.boolean :admin, null: false, default: false
    t.boolean :active, null: false, default: true
    t.timestamps
    t.index :api_token, unique: true
  end

  create_table :posts, force: true do |t|
    t.references :user, null: false, foreign_key: true
    t.string :title, null: false
    t.text :body
    t.timestamps
  end

  create_table :comments, force: true do |t|
    t.references :post, null: false, foreign_key: true
    t.references :user, null: false, foreign_key: true
    t.text :body
    t.timestamps
  end
end
