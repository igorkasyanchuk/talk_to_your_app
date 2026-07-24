# frozen_string_literal: true

require "rails/generators"

module TalkToYourApp
  module Generators
    # `rails g talk_to_your_app:install` — copies a commented initializer into
    # the host app. Configuration is initializer-only; there are no migrations
    # and no other generated files.
    class InstallGenerator < ::Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Creates config/initializers/talk_to_your_app.rb in the host app."

      def copy_initializer
        template "initializer.rb.tt", "config/initializers/talk_to_your_app.rb"
      end

      def show_next_steps
        say ""
        say "talk_to_your_app: edit config/initializers/talk_to_your_app.rb, then"
        say "mount the endpoint in config/routes.rb:", :green
        say "  mount TalkToYourApp.rack_app, at: TalkToYourApp.configuration.mount_at"
      end
    end
  end
end
