require "rails/generators/base"
require "rails/generators/active_record"

module ApprovalEngine
  module Generators
    # Copies the engine migrations into the host app and drops a configured
    # initializer.
    #
    #   rails generate approval_engine:install
    class InstallGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Installs ApprovalEngine: copies migrations and creates an initializer."

      def self.next_migration_number(dirname)
        ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      def create_initializer
        template "approval_engine.rb", "config/initializers/approval_engine.rb"
      end

      def copy_migrations
        rake "approval_engine:install:migrations"
      end

      def show_readme
        readme "POST_INSTALL" if behavior == :invoke
      end
    end
  end
end
