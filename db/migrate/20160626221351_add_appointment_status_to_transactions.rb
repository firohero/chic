class AddAppointmentStatusToTransactions < ActiveRecord::Migration
  def change
    add_column :transactions, :appointment_status, :string
  end
end
