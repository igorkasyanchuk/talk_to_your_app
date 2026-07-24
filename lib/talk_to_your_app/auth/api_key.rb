# frozen_string_literal: true

require "openssl"

module TalkToYourApp
  module Auth
    # Validates a Bearer token against the configured named API keys. The key's
    # name becomes the logged principal. Comparison is constant-time once lengths
    # match (a length mismatch short-circuits, which is acceptable: it leaks only
    # the key length, not its contents).
    module ApiKey
      module_function

      # Returns the principal name for a matching token, or nil.
      def principal_for(token, api_keys)
        return nil if token.nil? || token.empty? || api_keys.nil? || api_keys.empty?

        match = api_keys.find { |_name, key| secure_compare(token, key.to_s) }
        match&.first&.to_s
      end

      def secure_compare(given, expected)
        return false unless given.bytesize == expected.bytesize

        OpenSSL.fixed_length_secure_compare(given, expected)
      end
    end
  end
end
