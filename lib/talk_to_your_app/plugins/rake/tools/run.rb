# frozen_string_literal: true

require "open3"
require "timeout"
require_relative "../../../tool"

module TalkToYourApp
  module Plugins
    module Rake
      module Tools
        # Runs a single allow-listed rake task and returns its status and output
        # as JSON. The task must be on the plugin's `allowed:` list; anything
        # else is refused without executing. The task runs in a subprocess
        # (`bundle exec rake`), so it cannot inject shell commands and its real
        # exit status is captured.
        class Run < TalkToYourApp::Tool
          Result = Struct.new(:stdout, :stderr, :exit_code, keyword_init: true)

          # Cap captured output per stream so a chatty task can't balloon the web
          # process's memory; the child keeps running (drained past the cap) so it
          # still finishes normally. Grace window before escalating TERM to KILL.
          MAX_OUTPUT_BYTES = 1_000_000
          KILL_GRACE_SECONDS = 3

          name        "rake.run"
          description "Run an allow-listed rake task and return its status and output."
          argument    :task, :string, required: true, description: "Rake task name (must be allow-listed), e.g. \"stats\"."
          argument    :args, :array, description: "Positional task arguments, e.g. [\"42\"] for task[42]."

          def call(args, _ctx)
            task = args[:task].to_s
            unless TalkToYourApp::Plugins::Rake.allowed?(task)
              return error("Rake task #{task.inspect} is not allowed. Allowed tasks: #{TalkToYourApp::Plugins::Rake.allowed_tasks.inspect}.")
            end

            result = self.class.run_task(task, Array(args[:args]).map(&:to_s))
            json(
              task: task,
              status: result.exit_code.zero? ? "success" : "error",
              exit_code: result.exit_code,
              output: result.stdout.strip,
              error: (result.stderr.strip.empty? ? nil : result.stderr.strip),
            )
          rescue StandardError => e
            error("Failed to run rake #{args[:task]}: #{e.class}: #{e.message}")
          end

          # Executes `bundle exec rake <task>[args]` in the app root. Array argv
          # (no shell) so task/args cannot inject shell commands. The subprocess
          # is its own process group and is killed (TERM, then KILL) if it runs
          # longer than the configured timeout, so a hung or runaway task cannot
          # pin the calling web thread. Output is drained on threads — capped in
          # memory, but fully consumed — so a chatty task neither blocks on a
          # full pipe nor balloons the process.
          def self.run_task(task, rake_args)
            invocation = rake_args.empty? ? task : "#{task}[#{rake_args.join(",")}]"
            timeout = TalkToYourApp::Plugins::Rake.timeout

            Open3.popen3("bundle", "exec", "rake", invocation, chdir: app_root, pgroup: true) do |stdin, stdout, stderr, wait_thr|
              stdin.close
              out_reader = Thread.new { read_capped(stdout) }
              err_reader = Thread.new { read_capped(stderr) }

              if wait_thr.join(timeout).nil?
                terminate(wait_thr)
                [out_reader, err_reader].each(&:kill)
                raise Timeout::Error, "rake task #{invocation.inspect} exceeded the #{timeout}s timeout and was terminated"
              end

              Result.new(stdout: out_reader.value.to_s, stderr: err_reader.value.to_s, exit_code: wait_thr.value.exitstatus || 1)
            end
          end

          # Reads an IO to EOF but keeps only the first MAX_OUTPUT_BYTES; the rest
          # is drained and discarded so the child never blocks on a full pipe.
          def self.read_capped(io)
            buffer = +""
            capped = false
            while (chunk = io.read(16_384))
              next if capped

              buffer << chunk
              if buffer.bytesize >= MAX_OUTPUT_BYTES
                buffer = buffer.byteslice(0, MAX_OUTPUT_BYTES) << "\n[output truncated at #{MAX_OUTPUT_BYTES} bytes]"
                capped = true
              end
            end
            buffer
          rescue IOError
            # Pipe closed underneath us (e.g. the reader thread was killed on
            # timeout). Return whatever was captured so far.
            buffer
          end

          # Terminates the whole process group (negative pid) so `bundle exec
          # rake` and any children it spawned are taken down, escalating from
          # TERM to KILL if the group ignores TERM. Reaps the child either way.
          def self.terminate(wait_thr)
            pid = wait_thr.pid
            Process.kill("TERM", -pid)
            return if wait_thr.join(KILL_GRACE_SECONDS) # exited on TERM

            Process.kill("KILL", -pid)
            wait_thr.join # reap the killed child
          rescue Errno::ESRCH
            # Already exited between checks — nothing left to signal or reap.
          end

          def self.app_root
            defined?(Rails) && Rails.respond_to?(:root) ? Rails.root.to_s : Dir.pwd
          end
        end
      end
    end
  end
end
