require "rails/generators/base"

module ApprovalEngine
  module Generators
    # Copies an example approvals controller and views into the host app. They
    # are intentionally unstyled and minimal — you own them, theme them, rename
    # them. The engine ships the mechanism; the customer-facing UI is yours.
    #
    #   rails generate approval_engine:views
    class ViewsGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Copies example approval controller and views into your app to customise."

      def copy_controller
        copy_file "approvals_controller.rb", "app/controllers/approvals_controller.rb"
      end

      def copy_views
        directory "approvals", "app/views/approvals"
      end

      def routes_hint
        say "\nAdd routes for the copied controller, for example:", :green
        say <<~RUBY
          resources :approvals, only: :index do
            member { patch :approve; patch :reject }
          end
        RUBY
      end
    end
  end
end
