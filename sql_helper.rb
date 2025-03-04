# frozen_string_literal: true

require 'models/base_model'
require 'sequel'
require 'sequel/core'
require 'sqlite3'

Sequel.extension :migration

# Team city job will provide the migration files. For local, please copy the migration folder to vendor.
Dir.glob('vendor/db/migrations/*.rb').sort.each do |file|
  text = File.read(file)

  new_contents = text
  is_modified = text.include?('enum') || text.include?('alter_table') || text.include?('alter_table(:assets)')

  new_contents = new_contents.gsub(/enum/, 'String') if text.include?('enum')

  new_contents = new_contents.gsub(/:elements.*?\(.*?,/, '') if text.include?('alter_table')

  if text.include?('alter_table(:assets)')
    new_contents = new_contents.gsub(/:size => 255, :null => false/, ':size => 255, :null => true')
  end

  File.open(file, 'w') { |updated_file| updated_file.puts new_contents } if is_modified

  require file
end

Sequel::Model.plugin(:validation_class_methods)

# In-memory DB. gets cleared once the test run is complete.
# In memory sqlite documentation, https://www.rubydoc.info/gems/sequel/2.4.0/Sequel
DB = Sequel.sqlite

DB.extension(:connection_validator)
Sequel::Model.plugin :force_encoding, 'UTF-8'
Sequel::Model.plugin BaseModel::AutoTimestamps
Sequel::Model.plugin :json_serializer
Sequel.default_timezone = :utc
Sequel::Model.plugin :association_dependencies

Sequel::Migrator.run(DB, 'vendor/db/migrations')
