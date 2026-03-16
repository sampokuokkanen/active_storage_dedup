# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in active_storage_dedup.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

gem "rspec", "~> 3.0"

gem "rubocop", "~> 1.21"

# Database adapters — selected via DB env var
case ENV["DB"]
when "postgresql"
  gem "pg"
when "mysql"
  gem "mysql2"
else
  gem "sqlite3"
end
