class AddEmailToUsers < ActiveRecord::Migration[7.0]
  # The dummy actor needs a real address for the notification tests to resolve
  # one — `config.actor_email_method` defaults to :email.
  def change
    add_column :users, :email, :string
  end
end
