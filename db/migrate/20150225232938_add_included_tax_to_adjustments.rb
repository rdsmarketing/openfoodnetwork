class AddIncludedTaxToAdjustments < ActiveRecord::Migration
  def change
    add_column :spree_adjustments, :included_tax, :decimal, precision: 10, scale: 2
  end
end
