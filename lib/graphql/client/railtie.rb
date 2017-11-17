# frozen_string_literal: true
require "graphql"
require "graphql/client"
require "rails/railtie"

module GraphQL
  class Client
    # Optional Rails configuration for GraphQL::Client.
    #
    # Simply require this file to activate in the application.
    #
    #   # config/application.rb
    #   require "graphql/client/railtie"
    #
    class Railtie < Rails::Railtie
      config.graphql = ActiveSupport::OrderedOptions.new

      initializer "graphql.configure_log_subscriber" do |_app|
        require "graphql/client/log_subscriber"
        GraphQL::Client::LogSubscriber.attach_to :graphql
      end

      initializer "graphql.configure_erb_implementation" do |_app|
        require "graphql/client/erubis"
        ActionView::Template::Handlers::ERB.erb_implementation = GraphQL::Client::Erubis
      end

      initializer "graphql.configure_views_namespace" do |app|
        require "graphql/client/view_module"

        path = app.paths["app/views"].first

        config.watchable_dirs[path] = [:erb]

        Object.const_set(:Views, Module.new do
          extend GraphQL::Client::ViewModule
          self.path = path
        end)
      end
    end
  end
end
