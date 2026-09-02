# frozen_string_literal: true

require "pg"

module TalkToYourApp
  # Idempotently provisions the Postgres test database used by the DB-plugin
  # tests: a `ttya_test` database with a `widgets` table, and a genuinely
  # read-only role (`ttya_ro`, GRANT SELECT only) the gem connects through to
  # prove writes are rejected at the database layer.
  #
  # Connects via the `pg` gem (no psql CLI on PATH required). Returns true if
  # Postgres is reachable and provisioning succeeded, false otherwise so tests
  # can skip cleanly.
  module PgTestDb
    HOST = ENV.fetch("TTYA_TEST_DB_HOST", "localhost")
    PORT = Integer(ENV.fetch("TTYA_TEST_DB_PORT", 5432))
    SUPERUSER = ENV.fetch("TTYA_TEST_DB_USER", "postgres")

    module_function

    def available?
      return @available unless @available.nil?

      @available = setup
    end

    def setup
      admin = connect(dbname: "postgres")
      admin.exec("DROP DATABASE IF EXISTS ttya_test")
      admin.exec("DROP ROLE IF EXISTS ttya_ro")
      admin.exec("CREATE ROLE ttya_ro LOGIN PASSWORD 'ro_pass'")
      admin.exec("CREATE DATABASE ttya_test OWNER #{SUPERUSER}")
      admin.close

      db = connect(dbname: "ttya_test")
      db.exec(<<~SQL)
        CREATE TABLE widgets (id serial PRIMARY KEY, name text, quantity integer);
        INSERT INTO widgets (name, quantity) VALUES ('alpha', 3), ('beta', 7);
        GRANT CONNECT ON DATABASE ttya_test TO ttya_ro;
        GRANT USAGE ON SCHEMA public TO ttya_ro;
        GRANT SELECT ON ALL TABLES IN SCHEMA public TO ttya_ro;
        REVOKE CREATE ON SCHEMA public FROM ttya_ro;
      SQL
      db.close
      true
    rescue PG::Error, StandardError
      false
    end

    def connect(dbname:)
      PG.connect(host: HOST, port: PORT, user: SUPERUSER, dbname: dbname)
    end
  end
end
