module EasyredmineBudgetQuotas
  module TimeEntryValidation

    extend ActiveSupport::Concern
    included do
      before_save :check_if_budget_quota_valid, if: [:applies_on_budget_or_quota?, :project_uses_budget_quota?]
      before_save :verify_valid_from_to, if: [:is_budget_quota?, :project_uses_budget_quota?]
      after_create :set_self_ebq_budget_quota_id
      after_save :create_next_time_entry

      attr_accessor :remaining_values_for_assignment
    end

    def valid_from
      Date.parse(ebq_custom_field_value('ebq_valid_from')) rescue nil
    end

    def valid_to
      Date.parse(ebq_custom_field_value 'ebq_valid_to') rescue nil
    end

    def budget_quota_source
      ebq_custom_field_value 'ebq_budget_quota_source'
    end

    def budget_quota_value
      ebq_custom_field_value('ebq_budget_quota_value').to_f
    end

    def is_budget_quota?
      (EasyredmineBudgetQuotas.budget_entry_activities.ids + EasyredmineBudgetQuotas.quota_entry_activities.ids).include?(self.activity_id.to_i)
    end

    private

    #TODO: def CleanUp
    # ein Budget/ Quota was zu 100% voll ist,
    # der Maximalbetrag wird um unseren Toleranzbereich unter / überschritte
    # und alle Einträge sind geloggt -> exceeded setzten

    #TODO: unexeeded
    # wenn ein Budget / Quota Eintrag geunlocked wird, muss das exeeded Flag gelöscht werden

    def check_if_budget_quota_valid

      @remaining_values_for_assignment=nil

      # check if choosen source is available
      if budget_quota_source.to_s.match(/budget|quota/)


        # TODO: asurechnen was mit der aktuellen Activity 0.01 std. kosts
        # wenn = 0 abbrechen
        # wenn > 0 diesen Betrag als Differenzbetrag in die Berechnung der möglichenn Budgets / Quotas
        # übergeben

        current_bqs = self.project.get_current_budget_quota_entries(type: budget_quota_source.to_sym, ref_date: self.spent_on, required_min_budget_value: required_min_budget_value)

        if current_bqs.empty?
          self.errors.add(:ebq_budget_quota_source, "No #{budget_quota_source} is defined/available for this project at #{self.spent_on}")
          return false
        else

          # how much will this item cost?
          will_be_spent = EasyMoneyTimeEntryExpense.compute_expense(self, project.calculation_rate_id)

          # check if first BudgetQuota covers expense
          already_spent_on_entries = current_bqs.map {|bq| self.project.query_spent_entries_on(bq).map(&:price).sum }
          can_be_spent_on_entries  = current_bqs.map {|bq| bq.try(:budget_quota_value).to_f }

          already_spent = already_spent_on_entries.sum

          if self.persisted?
            # need to substract existing time entry
            r = EasyMoneyTimeEntryExpense.easy_money_time_entries_by_time_entry_and_rate_type(self, EasyMoneyRateType.find_by(name: project.budget_quotas_money_rate_type)).first
            already_spent -= r.price if r
          end

          # check if enough budget is available in all budgets/quotes to book the current timeentry
          if (can_be_spent_on_entries.sum + project.budget_quotas_tolerance_amount) < already_spent+will_be_spent
            self.errors.add(:ebq_budget_quota_value, "Limit of #{can_be_spent_on_entries.sum} for #{budget_quota_source} will be exceeded (#{already_spent+will_be_spent}) - cant add entry")
            return false
          elsif (can_be_spent_on_entries.first + project.budget_quotas_tolerance_amount) < already_spent_on_entries.first+will_be_spent
            # TODO: wenn ein Eintrag nicht über hours geteilt werden kann weil es z.B. eine
            # Reisekostenpauschale ist, dann muss er entweder vom nächsten Budgeteintrag aufgefangen werden
            # oder komplett abgelhnt werden, da er halt nicht Teilbar ist
            # das bekommst du darüber raus, dass die hours = 0 and will_be_spent > 0
            # musst du nach dem Stunden teilen checkn ob will_be_spent jetzt wirklich passt

            # current time entry cant be assigned on the first value
            # - calculate the value that actually can be assigned
            assignable_value = will_be_spent.to_f - ((already_spent_on_entries.first+will_be_spent).to_f - can_be_spent_on_entries.first)
            value_per_hour   = will_be_spent/self.hours

            assignable_hours = assignable_value/value_per_hour


            # store values for next time entry and close current BudgetQuota
            @remaining_values_for_assignment = self.attributes.merge('hours' => self.hours - assignable_hours)
            ## TODO: check, da jetzt im Comemnt oimmer der Comment ohne Index drin steht
            # und man damit einfach nur noch den IUndex anfügen Muss
            # TODO: als lokale Variable und diese hochzählen
            # get current index from comment
            comment_id = self.comments.match(/(?<=\[)[0-9]{1,}/).to_id rescue nil
            if comment_id.nil?
              self.comments = "[1] #{self.comments}"
            else
              self.comments = "[#{comment_id.to_i+1}] #{self.comments.gsub(/\[[0-9]{1,}\]\ /, '')}"
            end

            # TODO: hier muss in einer Liste vermekrt werden welche Budgets / Quotas im aktuellen
            # durchlafu schon probiert worden und diese düfen dann nicht mehr angesprochen werden
            current_bqs.first.update_column(:budget_quota_exceeded, true)

            # Assign currently applicable value
            self.hours = assignable_hours

            #assign_custom_field_value_for_ebq_budget_quota!(id: current_bqs.first.id, value: (assignable_hours*value_per_hour*-1).round(2))
            # recal will_be_spent on new hours
            will_be_spent = EasyMoneyTimeEntryExpense.compute_expense(self, project.calculation_rate_id)
          end

          assign_custom_field_value_for_ebq_budget_quota!(id: current_bqs.first.id, value: (-1*will_be_spent).round(2))
        end
      else
        self.errors.add(:ebq_budget_quota_source, "Invalid source name #{budget_quota_source}")
        return false
      end
    end

    def required_min_budget_value
      if @_required_min_budget_value.nil?
        fake_entry = self.dup
        fake_entry.hours = 0.01
        @_required_min_budget_value = EasyMoneyTimeEntryExpense.compute_expense(fake_entry, project.calculation_rate_id)
      end
      return @_required_min_budget_value
    end

    def create_next_time_entry
      return unless @remaining_values_for_assignment.present?

      next_entry = self.class.new(@remaining_values_for_assignment.except('id','user_id', 'tyear', 'tmonth', 'tweek'))
      # next line because of: WARNING: Can't mass-assign protected attributes for TimeEntry: user_id
      next_entry.user_id = self.user_id
      cf_source = self.available_custom_fields.detect {|cf| cf.internal_name == 'ebq_budget_quota_source' }
      next_entry.custom_field_values = {cf_source.id => self.budget_quota_source}
      next_entry.save
    end

    def assign_custom_field_value_for_ebq_budget_quota!(id: , value: )
      cf_id     = self.available_custom_fields.detect {|cf| cf.internal_name == 'ebq_budget_quota_id' }
      cf_value  = self.available_custom_fields.detect {|cf| cf.internal_name == 'ebq_budget_quota_value' }
      self.custom_field_values = {cf_id.id => id, cf_value.id => value}
    end

    def applies_on_quota?
      budget_quota_source == 'quota'
    end

    def applies_on_budget?
      budget_quota_source == 'budget'
    end

    def applies_on_budget_or_quota?
      applies_on_quota? || applies_on_budget?
    end

    def ebq_custom_field_value(v)
      self.custom_field_values.select {|f| f.custom_field.internal_name == v }.first.try(:value)
    end

    def verify_valid_from_to
      self.errors.add(:valid_from, 'required') if ebq_custom_field_value('ebq_valid_from').nil?
      self.errors.add(:valid_to, 'required') if ebq_custom_field_value('ebq_valid_to').nil?

      return self.errors.empty?
    end

    def set_self_ebq_budget_quota_id
      unless is_budget_quota?
        return
      else
        cf_id = self.available_custom_fields.detect {|cf| cf.internal_name == 'ebq_budget_quota_id' }
        self.custom_field_values = {cf_id.id => self.id}
      end
    end

    def project_uses_budget_quota?
      self.project.module_enabled?(:budget_quotas)
    end
  end
end