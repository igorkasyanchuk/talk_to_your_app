# frozen_string_literal: true

appraise "rails-7.2" do
  gem "rails", "~> 7.2.0"
end

appraise "rails-8.0" do
  gem "rails", "~> 8.0.0"
end

appraise "rails-8.1" do
  gem "rails", "~> 8.1.0"
end

# Lower bound of the mcp SDK requirement; the appraisals above resolve the
# newest 1.x, so the matrix covers both ends of `~> 1.1`.
appraise "rails-8.1-mcp-1.1" do
  gem "rails", "~> 8.1.0"
  gem "mcp", "1.1.0"
end
