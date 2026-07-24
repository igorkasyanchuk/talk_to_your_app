# frozen_string_literal: true

require "base64"

module TalkToYourApp
  module Auth
    # Validates an HTTP Basic credential by delegating to an operator-supplied
    # callable `(username, password) -> truthy`. The gem makes no assumption
    # about the host app's user model. The username becomes the principal.
    module Basic
      module_function

      def principal_for(encoded, callable)
        return nil if encoded.nil? || encoded.empty? || callable.nil?

        decoded = Base64.decode64(encoded)
        username, password = decoded.split(":", 2)
        return nil if username.nil? || username.empty?

        callable.call(username, password) ? username : nil
      end
    end
  end
end
