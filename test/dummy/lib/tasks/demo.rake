# frozen_string_literal: true

# Demo rake tasks exposed (allow-listed) through the Rake plugin.
namespace :demo do
  desc "Print database stats (no arguments)"
  task stats: :environment do
    puts "users=#{User.count} posts=#{Post.count} comments=#{Comment.count}"
  end

  desc "Greet someone (one argument)"
  task :echo, [:message] => :environment do |_t, args|
    puts "Hello, #{args[:message] || "world"}!"
  end
end
