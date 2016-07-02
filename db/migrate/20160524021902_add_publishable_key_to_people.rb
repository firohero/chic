class AddPublishableKeyToPeople < ActiveRecord::Migration
  def change
    add_column :people, :stripe_publishable_key, :string
    add_column :people, :stripe_provider, :string
    add_column :people, :stripe_uid, :string
    add_column :people, :stripe_access_code, :string
  end
end
