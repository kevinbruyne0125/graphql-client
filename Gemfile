# frozen_string_literal: true
source "https://rubygems.org"
gemspec

gem "actionpack", ENV["RAILS_VERSION"] if ENV["RAILS_VERSION"]
gem "activesupport", ENV["RAILS_VERSION"] if ENV["RAILS_VERSION"]

graphql_version = ENV["GRAPHQL_VERSION"] == "1.8-dev" ? { github: "rmosolgo/graphql-ruby", branch: "1.8-dev" } : ENV["GRAPHQL_VERSION"]
if graphql_version
  gem "graphql", version
end


group :development, :test do
  gem "rubocop", "~> 0.51"
end
