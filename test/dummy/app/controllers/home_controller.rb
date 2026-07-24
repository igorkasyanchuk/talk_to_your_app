# frozen_string_literal: true

require "cgi"

# Root page for the dummy app: a quick at-a-glance view of what's in the
# database, plus a pointer to the mounted MCP endpoint. Renders a small HTML
# page (the app runs in api_only mode, so there are no view templates).
class HomeController < ApplicationController
  def index
    stats = {
      "Users" => User.count,
      "Posts" => Post.count,
      "Comments" => Comment.count,
      "Widgets" => widget_count,
    }
    recent_posts = Post.order(created_at: :desc).limit(5)
                       .map { |p| "#{p.title} — by #{p.user.name}" }
    users = User.order(:id).select(:name, :email, :api_token, :admin, :active)
    activities = Activity.order(created_at: :desc).limit(8)
                         .map { |a| "#{a.created_at.utc.strftime("%H:%M:%S")} · #{a.tool} · #{a.principal || "?"} · #{a.ip} · #{a.outcome}" }

    render html: page(stats, recent_posts, users, activities).html_safe
  end

  private

  def widget_count
    ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM widgets").to_i
  rescue ActiveRecord::StatementInvalid
    0
  end

  def page(stats, recent_posts, users, activities)
    rows = stats.map { |label, count| "<tr><td>#{esc(label)}</td><td>#{count}</td></tr>" }.join
    posts = recent_posts.map { |line| "<li>#{esc(line)}</li>" }.join
    activity = activities.map { |line| "<li><code>#{esc(line)}</code></li>" }.join
    user_rows = users.map do |u|
      "<tr><td>#{esc(u.name)}</td><td>#{esc(u.email)}</td><td><code>#{esc(u.api_token)}</code></td>" \
        "<td>#{u.admin ? "admin" : ""}</td><td>#{u.active ? "active" : "inactive"}</td></tr>"
    end.join
    mount = TalkToYourApp.configuration.mount_at
    <<~HTML
      <!doctype html>
      <html><head><meta charset="utf-8"><title>talk_to_your_app — dummy app</title>
      <style>
        body { font: 16px/1.5 system-ui, sans-serif; max-width: 48rem; margin: 3rem auto; padding: 0 1rem; }
        h1 { margin-bottom: 0.25rem; } .muted { color: #666; }
        table { border-collapse: collapse; margin: 1rem 0; } th, td { border: 1px solid #ddd; padding: 0.3rem 0.8rem; text-align: left; }
        .stats td:last-child { text-align: right; font-variant-numeric: tabular-nums; }
        code { background: #f4f4f4; padding: 0.1rem 0.35rem; border-radius: 3px; }
      </style></head>
      <body>
        <h1>talk_to_your_app</h1>
        <p class="muted">Dummy app — database stats</p>
        <table class="stats"><tbody>#{rows}</tbody></table>

        <h2>Recent posts</h2>
        <ul>#{posts.empty? ? "<li class='muted'>none yet</li>" : posts}</ul>

        <h2>Users &amp; API tokens</h2>
        <p class="muted">Each token is a Bearer key for the MCP endpoint; the
        user's name is the logged principal. (Dev only — never expose tokens
        like this in production.)</p>
        <table><thead><tr><th>Name</th><th>Email</th><th>API token</th><th>Admin</th><th>Active</th></tr></thead>
        <tbody>#{user_rows}</tbody></table>

        <h2>Recent activity (audit log)</h2>
        <ul>#{activity.empty? ? "<li class='muted'>no tool calls yet</li>" : activity}</ul>

        <p class="muted">MCP endpoint mounted at <code>#{esc(mount)}</code>.
        Connect with <code>Authorization: Bearer &lt;token&gt;</code> or HTTP
        Basic — see <code>LOCAL_DEVELOPMENT.md</code>.</p>
      </body></html>
    HTML
  end

  def esc(value)
    CGI.escape_html(value.to_s)
  end
end
