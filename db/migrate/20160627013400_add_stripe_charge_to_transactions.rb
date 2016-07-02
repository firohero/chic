class AddStripeChargeToTransactions < ActiveRecord::Migration
  def change
    add_column :transactions, :stripe_charge, :string
  end
end
