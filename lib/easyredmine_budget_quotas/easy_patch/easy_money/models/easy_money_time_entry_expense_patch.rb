module EasyredmineBudgetQuotas
  module EasyMoneyTimeEntryExpensePatch

    def self.included(base)
      base.extend(ClassMethods)
      base.send(:include, InstanceMethods)

      base.class_eval do

        class << self

          alias_method_chain :compute_expense, :modification_akquinet

        end

      end
    end

    module InstanceMethods

    end

    module ClassMethods

      def compute_expense_with_modification_akquinet(time_entry, rate_type)
        # if time entry is easy billable or
        # setting for 'only billable time entries' for given rate is set to false
        if time_entry.easy_is_billable? || time_entry.project.ebq_rate_type_settings[rate_type.to_s] == '0'
          multiplied = time_entry.custom_field_values.select{|cfv| !cfv.value.blank? && cfv.custom_field.akquinet_extra_money_multiplied?}.
            collect{|cf| cf.value.to_f}.sum
          offset = time_entry.custom_field_values.select{|cfv| !cfv.value.blank? && cfv.custom_field.akquinet_extra_money_offset?}.
            collect{|cf| cf.value.to_f}.sum

          ((time_entry.hours.to_f + multiplied) * EasyMoneyRate.get_unit_rate_for_time_entry(time_entry, rate_type)) + offset
        else
           # setting for 'only billable time entries' for given rate is set to true and item is not billable
          0
        end
      end

    end

  end

end
EasyExtensions::PatchManager.register_model_patch 'EasyMoneyTimeEntryExpense', 'EasyredmineBudgetQuotas::EasyMoneyTimeEntryExpensePatch'
