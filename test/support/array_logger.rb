# frozen_string_literal: true

require "logger"
require "stringio"

module TalkToYourApp
  # A Logger that captures emitted lines (after level filtering) for assertions.
  # A real (discarded) log device is required so Logger#add still applies level
  # filtering and invokes the formatter, where we capture the message.
  class ArrayLogger < ::Logger
    attr_reader :lines

    def initialize(level: ::Logger::INFO)
      @lines = []
      super(StringIO.new)
      self.level = level
      self.formatter = ->(severity, _ts, _prog, msg) { record(severity, msg) }
    end

    def record(severity, message)
      @lines << { severity: severity, message: message }
      ""
    end

    def messages_at(severity)
      @lines.select { |l| l[:severity] == severity }.map { |l| l[:message] }
    end
  end
end
