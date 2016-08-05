class AddBusinessHoursToPeople < ActiveRecord::Migration
  def change
    add_column :people, :mon, :boolean
    add_column :people, :tue, :boolean
    add_column :people, :wed, :boolean
    add_column :people, :thu, :boolean
    add_column :people, :fri, :boolean
    add_column :people, :sat, :boolean
    add_column :people, :sun, :boolean
    add_column :people, :hour0, :boolean
    add_column :people, :hour1, :boolean
    add_column :people, :hour2, :boolean
    add_column :people, :hour3, :boolean
    add_column :people, :hour4, :boolean
    add_column :people, :hour5, :boolean
    add_column :people, :hour6, :boolean
    add_column :people, :hour7, :boolean
    add_column :people, :hour8, :boolean
    add_column :people, :hour9, :boolean
    add_column :people, :hour10, :boolean
    add_column :people, :hour11, :boolean
    add_column :people, :hour12, :boolean
    add_column :people, :hour13, :boolean
    add_column :people, :hour14, :boolean
    add_column :people, :hour15, :boolean
    add_column :people, :hour16, :boolean
    add_column :people, :hour17, :boolean
    add_column :people, :hour18, :boolean
    add_column :people, :hour19, :boolean
    add_column :people, :hour20, :boolean
    add_column :people, :hour21, :boolean
    add_column :people, :hour22, :boolean
    add_column :people, :hour23, :boolean
  end
end
