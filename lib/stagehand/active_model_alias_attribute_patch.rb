# Workaround for a Rails 7.1+ regression where calling
# `alias_attribute(new_name, old_name)` repeatedly with the same arguments
# appends duplicate entries to `aliases_by_attribute_name[old_name]`. When
# combined with `ActiveRecord::Base#load_schema!`'s auto-registration of
# `alias_attribute :id_value, :id` on every schema reload, any class whose
# `table_name` is swapped at runtime (as Stagehand::Production::Record does
# via `prepare_to_modify`) accumulates duplicates and pays quadratically-
# growing method-generation cost on subsequent queries.
#
# Rails 7.0 and earlier are unaffected (neither `aliases_by_attribute_name`
# nor the `:id_value` auto-alias exist before 7.1), so the patch is applied
# only when the affected API surface is present.
#
# Upstream fix: https://github.com/rails/rails/pull/57227
# Remove this file once Stagehand's minimum Rails requirement contains the
# upstream fix.
module Stagehand
  module ActiveModelAliasAttributePatch
    def alias_attribute(new_name, old_name)
      new_name_s = new_name.to_s
      old_name_s = old_name.to_s
      return if attribute_aliases[new_name_s] == old_name_s &&
                aliases_by_attribute_name[old_name_s].include?(new_name_s)

      super
    end
  end
end

if ActiveModel::AttributeMethods::ClassMethods.method_defined?(:aliases_by_attribute_name)
  ActiveModel::AttributeMethods::ClassMethods.prepend(Stagehand::ActiveModelAliasAttributePatch)
end
