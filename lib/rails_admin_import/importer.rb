require "rails_admin_import/import_logger"

module RailsAdminImport
  class Importer
    def initialize(import_model, params)
      @current_row = 0
      @import_model = import_model
      @params = params
      @fuzzy_matches = []
    end

    attr_reader :import_model, :params

    class UpdateLookupError < StandardError; end

    def import(records)
      init_results

      if records.count > RailsAdminImport.config.line_item_limit
        return results = {
          success: [],
          warning: [],
          error: [I18n.t("admin.import.import_error.line_item_limit", limit: RailsAdminImport.config.line_item_limit)]
        }
      end

      perform_global_callback(:before_import)

      with_transaction do
        # Skip the header row
        records.each.with_index(2) do |record, index|
          begin
            @current_row = index
            catch :skip do
              begin
                import_record(record)
              rescue Exception => e
                # Log the error but do not stop the loop
                report_general_error("#{e} (#{e.backtrace.first})")
              end
            end
          ensure
            @current_row = index
          end
        end

        rollback_if_error_or_warning # Check errors and possibly rollback after all records have been processed
      end

      perform_global_callback(:after_import)
      format_results
    end

    private

    def init_results
      @results = { success: [], error: [], warning: [] }
    end

    def with_transaction(&block)
      if RailsAdminImport.config.rollback_on_error && defined?(ActiveRecord)
        ActiveRecord::Base.transaction(&block)
      else
        block.call
      end
    end

    def rollback_if_error_or_warning
      if RailsAdminImport.config.rollback_on_error &&
         defined?(ActiveRecord) &&
         (results[:error].any? || results[:warning].any?)

        results[:success] = []
        raise ActiveRecord::Rollback
      end
    end

    def import_record(record)
      if params["file"] && RailsAdminImport.config.pass_filename
        record.merge!({ filename_importer: params[:file].original_filename })
      end

      perform_model_callback(import_model.model, :before_import_find, record)

      if update_lookup && !(update_lookup - record.keys).empty?
        raise UpdateLookupError, I18n.t("admin.import.missing_update_lookup")
      end

      object = find_or_create_object(record, update_lookup)
      return if object.nil?
      action = object.new_record? ? :create : :update

      # Fuzzy Search
      if import_model.display_name == "Project" && params[:skip_fuzzy_search] != "1" && action == :create && (record[:groups].present? || record[:group].present?)
        query_key = params[:associations]["groups"]
        projects = Project.joins(:groups).where(groups: { query_key => (record[:groups] || record[:group]) }).fuzzy_name(object.full_name)
        if projects.present?
          @fuzzy_matches << { object: object, matches: projects, row: @current_row }
          message = "#{projects.count} project#{projects.count > 1 ? "s" : ""} found with similar full name: #{object.full_name}"
          report_warning(object, message)
        end
      end

      begin
        perform_model_callback(object, :before_import_associations, record)
        import_single_association_data(object, record)
        import_many_association_data(object, record)
      rescue AssociationNotFound => e
        error = I18n.t("admin.import.association_not_found", error: e.to_s)
        report_error(object, action, error)
        perform_model_callback(object, :after_import_association_error, record)
        return
      end

      perform_model_callback(object, :before_import_save, record)

      if object.save
        report_success(object, action)
        perform_model_callback(object, :after_import_save, record)
      else
        message = object.errors.full_messages.join(", ")
        report_error(object, action, message)
        perform_model_callback(object, :after_import_error, record)
      end
    end

    def update_lookup
      @update_lookup ||= if params[:update_if_exists] == "1"
                           params[:update_lookup].map(&:to_sym)
                         end
    end

    attr_reader :results

    def logger
      @logger ||= ImportLogger.new
    end

    def report_success(object, action)
      object_label = import_model.label_for_model(object)
      message = I18n.t("admin.import.import_success.#{action}", name: object_label)
      logger.info "#{Time.now}: #{message}"
      results[:success] << message
    end

    def report_error(object, action, error)
      object_label = import_model.label_for_model(object)
      message = I18n.t("admin.import.import_error.#{action}", name: object_label, error: @current_row ? "#{error} (row #{@current_row})" : error)
      logger.info "#{Time.now}: #{message}"
      results[:error] << message
    end

    def report_warning(object, warning)
      object_label = import_model.label_for_model(object)
      message = "#{warning} (row #{@current_row})"
      logger.info "#{Time.now}: #{message}"
      results[:warning] << message
    end

    def report_general_error(error)
      message = I18n.t("admin.import.import_error.general", error: @current_row ? "#{error} (row #{@current_row})" : error)
      logger.info "#{Time.now}: #{message}"
      results[:error] << message
    end

    def format_results
      imported = results[:success]
      not_imported = results[:error]
      warnings = results[:warning]
      unless imported.empty?
        results[:success_message] = format_result_message("successful", imported)
      end
      unless warnings.empty?
        results[:warning_message] = "#{warnings.size} warning#{warnings.size > 1 ? "s" : ""}"
      end
      unless not_imported.empty?
        results[:error_message] = format_result_message("error", not_imported)
      end

      results
    end

    def format_result_message(type, array)
      result_count = "#{array.size} #{import_model.display_name.pluralize(array.size)}"
      I18n.t("admin.flash.#{type}", name: result_count, action: I18n.t("admin.actions.import.done"))
    end

    def perform_model_callback(object, method_name, record)
      if object.respond_to?(method_name)
        # Compatibility: Old import hook took 2 arguments.
        # Warn and call with a blank hash as 2nd argument.
        if object.method(method_name).arity == 2
          report_old_import_hook(method_name)
          object.send(method_name, record, {})
        else
          object.send(method_name, record)
        end
      end
    end

    def report_old_import_hook(method_name)
      unless @old_import_hook_reported
        error = I18n.t("admin.import.import_error.old_import_hook", model: import_model.display_name, method: method_name)
        report_general_error(error)
        @old_import_hook_reported = true
      end
    end

    def perform_global_callback(method_name)
      object = import_model.model
      object.send(method_name) if object.respond_to?(method_name)
    end

    def find_or_create_object(record, update)
      model = import_model.model
      object = if update.present?
                 query = update.each_with_object({}) do |field, query|
                   query[field] = record[field]
                 end
                 model.where(query).first
               end

      object ||= model.new

      perform_model_callback(object, :before_import_attributes, record)

      field_names = import_model.model_fields.map(&:name)
      new_attrs = record.select do |field_name, value|
        field_names.include?(field_name) && (!value.blank? || value == false)
      end

      if object.new_record?
        object.attributes = new_attrs
      else
        object.attributes = new_attrs.except(update.map(&:to_sym))
      end
      object
    end

    def import_single_association_data(object, record)
      import_model.single_association_fields.each do |field|
        mapping_key = params[:associations][field.name]
        value = extract_mapping(record[field.name], mapping_key)

        if !value.blank?
          object.send("#{field.name}=", import_model.associated_object(field, mapping_key, value))
        end
      end
    end

    def import_many_association_data(object, record)
      import_model.many_association_fields.each do |field|
        if record.key?(field.name)
          mapping_key = params[:associations][field.name]
          values = record[field.name].reject(&:blank?).map { |value| extract_mapping(value, mapping_key) }

          if values.any?
            associated = values.map { |value| import_model.associated_object(field, mapping_key, value) }
            object.send("#{field.name}=", associated)
          end
        end
      end
    end

    def extract_mapping(value, mapping_key)
      value.is_a?(Hash) ? value[mapping_key] : value
    end
  end
end
