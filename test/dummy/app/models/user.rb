# frozen_string_literal: true

class User < ApplicationRecord
  has_many :posts, dependent: :destroy
  has_many :comments, dependent: :destroy

  # Per-user API token, auto-generated on create. In this demo the token doubles
  # as the user's MCP Bearer key (see config/initializers/talk_to_your_app.rb).
  has_secure_token :api_token
end
