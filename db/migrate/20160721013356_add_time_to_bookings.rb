class AddTimeToBookings < ActiveRecord::Migration
  def change
    add_column :bookings, :start_at, :datetime
    add_column :bookings, :end_at, :datetime
  end
end
