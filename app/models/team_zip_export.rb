# frozen_string_literal: true

require 'zip'
require 'fileutils'
require 'csv'

class TeamZipExport < ZipExport
  include StringUtility

  # Override path only for S3
  if ENV['PAPERCLIP_STORAGE'] == 's3'
    s3_path =
      if ENV['S3_SUBFOLDER']
        "/#{ENV['S3_SUBFOLDER']}/zip_exports/:attachment/"\
        ":id_partition/:hash/:style/:filename"
      else
        '/zip_exports/:attachment/:id_partition/:hash/:style/:filename'
      end

    has_attached_file :zip_file, path: s3_path
    validates_attachment :zip_file,
                         content_type: { content_type: 'application/zip' }
  end

  def generate_exportable_zip(user, data, type, options = {})
    @user = user
    zip_input_dir = FileUtils.mkdir_p(
      File.join(Rails.root, "tmp/temp_zip_#{Time.now.to_i}")
    ).first
    zip_dir = FileUtils.mkdir_p(File.join(Rails.root, 'tmp/zip-ready')).first
    zip_file = File.new(
      File.join(zip_dir,
                "projects_export_#{Time.now.strftime('%F_%H-%M-%S')}.zip"),
      'w+'
    )
    fill_content(zip_input_dir, data, type, options)
    zip!(zip_input_dir, zip_file)
    self.zip_file = File.open(zip_file)
    generate_notification(user) if save
  ensure
    FileUtils.rm_rf([zip_input_dir, zip_file], secure: true)
  end

  handle_asynchronously :generate_exportable_zip,
                        queue: :team_zip_export

  private

  # Export all functionality
  def generate_teams_zip(tmp_dir, data, options = {})
    # Create team folder
    @team = options[:team]
    team_path = "#{tmp_dir}/#{to_filesystem_name(@team.name)}"
    FileUtils.mkdir_p(team_path)

    # Iterate through every project
    p_idx = p_archive_idx = 0
    data.each do |(_, p)|
      idx = p.archived ? (p_archive_idx += 1) : (p_idx += 1)
      project_path = make_model_dir(team_path, p, idx)
      project_name = project_path.split('/')[-1]

      obj_filenames = { my_module_repository: {}, step_asset: {},
                        step_table: {}, result_asset: {}, result_table: {} }

      # Change current dir for correct generation of relative links
      Dir.chdir(project_path)
      project_path = '.'

      inventories = "#{project_path}/Inventories"
      FileUtils.mkdir_p(inventories)

      # Find all assigned inventories through all tasks in the project
      task_ids = p.project_my_modules
      repo_rows = RepositoryRow.joins(:my_modules)
                               .where(my_modules: { id: task_ids })
                               .distinct

      # Iterate through every inventory repo and save it to CSV
      repo_rows.map(&:repository).uniq.each_with_index do |repo, repo_idx|
        curr_repo_rows = repo_rows.select { |x| x.repository_id == repo.id }
        obj_filenames[:my_module_repository][repo.id] =
          save_inventories_to_csv(inventories, repo, curr_repo_rows, repo_idx)
      end

      # Include all experiments
      ex_idx = ex_archive_idx = 0
      p.experiments.each do |ex|
        idx = ex.archived ? (ex_archive_idx += 1) : (ex_idx += 1)
        experiment_path = make_model_dir(project_path, ex, idx)

        # Include all modules
        mod_pos = mod_archive_pos = 0
        ex.my_modules.order(:workflow_order).each do |my_module|
          pos = my_module.archived ? (mod_archive_pos += 1) : (mod_pos += 1)
          my_module_path = make_model_dir(experiment_path, my_module, pos)

          # Create upper directories for both elements
          protocol_path = "#{my_module_path}/Protocol attachments"
          result_path = "#{my_module_path}/Result attachments"
          FileUtils.mkdir_p(protocol_path)
          FileUtils.mkdir_p(result_path)

          # Export protocols
          steps = my_module.protocols.map(&:steps).flatten
          obj_filenames[:step_asset].merge!(
            export_assets(StepAsset.where(step: steps), :step, protocol_path)
          )
          obj_filenames[:step_table].merge!(
            export_tables(StepTable.where(step: steps), :step, protocol_path)
          )

          # Export results
          obj_filenames[:result_asset].merge!(
            export_assets(ResultAsset.where(result: my_module.results),
                          :result, result_path)
          )
          obj_filenames[:result_table].merge!(
            export_tables(ResultTable.where(result: my_module.results),
                          :result, result_path)
          )
        end
      end

      # Generate and export whole project report HTML
      html_name = "#{project_name} Report.html"
      project_report_pdf = p.generate_teams_export_report_html(
        @user, @team, html_name, obj_filenames
      )
      file = FileUtils.touch("#{project_path}/#{html_name}").first
      File.open(file, 'wb') { |f| f.write(project_report_pdf) }
    end

    # Change current dir outside tmp_dir, since tmp_dir will be deleted
    Dir.chdir(File.join(Rails.root, 'tmp'))
  end

  def generate_notification(user)
    notification = Notification.create(
      type_of: :deliver,
      title: I18n.t('zip_export.notification_title'),
      message:  "<a data-id='#{id}' " \
                "href='#{Rails.application
                              .routes
                              .url_helpers
                              .zip_exports_download_export_all_path(self)}'>" \
                "#{zip_file_file_name}</a>"
    )
    UserNotification.create(notification: notification, user: user)
  end

  # Create directory for project, experiment, or module
  def make_model_dir(parent_path, model, index)
    # For MyModule, the index indicates its position in project sidebar
    if model.class == MyModule
      class_name = 'module'
      model_format = '(%<idx>s) %<name>s'
    else
      class_name = model.class.to_s.downcase.pluralize
      model_format = '%<name>s (%<idx>s)'
    end
    model_name =
      format(model_format, idx: index, name: to_filesystem_name(model.name))

    model_path = parent_path
    if model.archived
      model_path += "/Archived #{class_name}"
      FileUtils.mkdir_p(model_path)
    end
    model_path += "/#{model_name}"
    FileUtils.mkdir_p(model_path)
    model_path
  end

  # Appends given suffix to file_name and then adds original extension
  def append_file_suffix(file_name, suffix)
    ext = File.extname(file_name)
    File.basename(file_name, ext) + suffix + ext
  end

  # Helper method to extract given assets to the directory
  def export_assets(elements, type, directory)
    asset_indexes = {}

    elements.each_with_index do |element, i|
      asset = element.asset

      if type == :step
        name = "#{directory}/" \
               "#{append_file_suffix(asset.file_file_name,
                                     "_#{i}_Step#{element.step.position + 1}")}"
      elsif type == :result
        name = "#{directory}/#{append_file_suffix(asset.file_file_name,
                                                  "_#{i}")}"
      end
      file = FileUtils.touch(name).first
      if asset.file.exists?
        File.open(file, 'wb') do |f|
          f.write(Paperclip.io_adapters.for(asset.file).read)
        end
      end
      asset_indexes[asset.id] = name
    end

    asset_indexes
  end

  # Helper method to extract given tables to the directory
  def export_tables(elements, type, directory)
    table_indexes = {}

    elements.each_with_index do |element, i|
      table = element.table
      table_name = table.name.presence || 'Table'
      table_name += i.to_s

      if type == :step
        name = "#{directory}/#{to_filesystem_name(table_name)}" \
               "_#{i}_Step#{element.step.position + 1}.csv"
      elsif type == :result
        name = "#{directory}/#{to_filesystem_name(table_name)}.csv"
      end
      file = FileUtils.touch(name).first
      File.open(file, 'wb') { |f| f.write(table.to_csv) }
      table_indexes[table.id] = name
    end

    table_indexes
  end

  # Helper method for saving inventories to CSV
  def save_inventories_to_csv(path, repo, repo_rows, idx)
    repo_name = "#{to_filesystem_name(repo.name)} (#{idx})"

    # Attachment folder
    rel_attach_path = "#{repo_name} attachments"
    attach_path = "#{path}/#{rel_attach_path}"
    FileUtils.mkdir_p(attach_path)

    # CSV file
    csv_file_path = "#{path}/#{repo_name}.csv"
    csv_file = FileUtils.touch(csv_file_path).first

    # Define headers and columns IDs
    col_ids = [-3, -4, -5, -6] + repo.repository_columns.map(&:id)

    # Define callback function for file name
    assets = {}
    asset_counter = 0
    handle_name_func = lambda do |asset|
      file_name = append_file_suffix(asset.file_file_name,
                                     "_#{asset_counter}").to_s

      # Save pair for downloading it later
      assets[asset] = "#{attach_path}/#{file_name}"

      asset_counter += 1
      rel_path = "#{rel_attach_path}/#{file_name}"
      return "=HYPERLINK(\"#{rel_path}\", \"#{rel_path}\")"
    end

    # Generate CSV
    csv_data = RepositoryZipExport.to_csv(repo_rows, col_ids, @user, @team,
                                          handle_name_func)
    File.open(csv_file, 'wb') { |f| f.write(csv_data) }

    # Save all attachments (it doesn't work directly in callback function
    assets.each do |asset, asset_path|
      file = FileUtils.touch(asset_path).first
      File.open(file, 'wb') { |f| f.write asset.open.read }
    end

    csv_file_path
  end

  # Recursive zipping
  def zip!(input_dir, output_file)
    files = Dir.entries(input_dir)

    # Don't zip current/above directory
    files.delete_if { |el| ['.', '..'].include?(el) }

    Zip::File.open(output_file.path, Zip::File::CREATE) do |zipfile|
      write_entries(input_dir, files, '', zipfile)
    end
  end

  # A helper method to make the recursion work.
  def write_entries(input_dir, entries, path, io)
    entries.each do |e|
      zip_file_path = path == '' ? e : File.join(path, e)
      disk_file_path = File.join(input_dir, zip_file_path)
      puts 'Deflating ' + disk_file_path
      if File.directory?(disk_file_path)
        io.mkdir(zip_file_path)
        subdir = Dir.entries(disk_file_path)

        # Remove current/above directory to prevent infinite recursion
        subdir.delete_if { |el| ['.', '..'].include?(el) }

        write_entries(input_dir, subdir, zip_file_path, io)
      else
        io.get_output_stream(zip_file_path) do |f|
          f.puts File.open(disk_file_path, 'rb').read
        end
      end
    end
  end
end
