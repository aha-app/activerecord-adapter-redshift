# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module Redshift
      class SchemaCreation < SchemaCreation
        private

        def visit_ColumnDefinition(o)
          o.sql_type = type_to_sql(o.type, limit: o.limit, precision: o.precision, scale: o.scale)
          super
        end

        def add_column_options!(sql, options)
          column = options.fetch(:column) { return super }
          if column.type == :uuid && options[:default] =~ /\(\)/
            sql << " DEFAULT #{options[:default]}"
          else
            super
          end
        end
      end

      module SchemaStatements
        # Drops the database specified on the +name+ attribute
        # and creates it again using the provided +options+.
        def recreate_database(name, options = {}) # :nodoc:
          drop_database(name)
          create_database(name, options)
        end

        # Create a new Redshift database. Options include <tt>:owner</tt>, <tt>:template</tt>,
        # <tt>:encoding</tt> (defaults to utf8), <tt>:collation</tt>, <tt>:ctype</tt>,
        # <tt>:tablespace</tt>, and <tt>:connection_limit</tt> (note that MySQL uses
        # <tt>:charset</tt> while Redshift uses <tt>:encoding</tt>).
        #
        # Example:
        #   create_database config[:database], config
        #   create_database 'foo_development', encoding: 'unicode'
        def create_database(name, options = {})
          options = { encoding: 'utf8' }.merge!(options.symbolize_keys)

          option_string = options.inject('') do |memo, (key, value)|
            next memo unless key == :owner

            memo + " OWNER = \"#{value}\""
          end

          execute "CREATE DATABASE #{quote_table_name(name)}#{option_string}"
        end

        # Drops a Redshift database.
        #
        # Example:
        #   drop_database 'matt_development'
        def drop_database(name) # :nodoc:
          execute "DROP DATABASE #{quote_table_name(name)}"
        end

        # Returns an array of table names defined in the database.
        def tables
          select_values('SELECT tablename FROM pg_tables WHERE schemaname = ANY(current_schemas(false))', 'SCHEMA')
        end

        # :nodoc
        def data_sources
          select_values(<<-SQL, 'SCHEMA')
            SELECT c.relname
            FROM pg_class c
            LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('r', 'v','m') -- (r)elation/table, (v)iew, (m)aterialized view
            AND n.nspname = ANY (current_schemas(false))
          SQL
        end

        # Returns true if table exists.
        # If the schema is not specified as part of +name+ then it will only find tables within
        # the current schema search path (regardless of permissions to access tables in other schemas)
        def table_exists?(name)
          name = Utils.extract_schema_qualified_name(name.to_s)
          return false unless name.identifier

          select_value(<<-SQL, 'SCHEMA').to_i > 0
              SELECT COUNT(*)
              FROM pg_class c
              LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE c.relkind = 'r' -- (r)elation/table
              AND c.relname = '#{name.identifier}'
              AND n.nspname = #{name.schema ? "'#{name.schema}'" : 'ANY (current_schemas(false))'}
          SQL
        end

        def data_source_exists?(name)
          name = Utils.extract_schema_qualified_name(name.to_s)
          return false unless name.identifier

          select_value(<<-SQL, 'SCHEMA').to_i > 0
              SELECT COUNT(*)
              FROM pg_class c
              LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE c.relkind IN ('r','v','m') -- (r)elation/table, (v)iew, (m)aterialized view
              AND c.relname = '#{name.identifier}'
              AND n.nspname = #{name.schema ? "'#{name.schema}'" : 'ANY (current_schemas(false))'}
          SQL
        end

        def views # :nodoc:
          select_values(<<-SQL, 'SCHEMA')
            SELECT c.relname
            FROM pg_class c
            LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('v','m') -- (v)iew, (m)aterialized view
            AND n.nspname = ANY (current_schemas(false))
          SQL
        end

        def view_exists?(view_name) # :nodoc:
          name = Utils.extract_schema_qualified_name(view_name.to_s)
          return false unless name.identifier

          select_values(<<-SQL, 'SCHEMA').any?
            SELECT c.relname
            FROM pg_class c
            LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('v','m') -- (v)iew, (m)aterialized view
            AND c.relname = '#{name.identifier}'
            AND n.nspname = #{name.schema ? "'#{name.schema}'" : 'ANY (current_schemas(false))'}
          SQL
        end

        def drop_table(table_name, **options)
          execute "DROP TABLE#{' IF EXISTS' if options[:if_exists]} #{quote_table_name(table_name)}#{' CASCADE' if options[:force] == :cascade}"
        end

        # Returns true if schema exists.
        def schema_exists?(name)
          select_value("SELECT COUNT(*) FROM pg_namespace WHERE nspname = '#{name}'", 'SCHEMA').to_i > 0
        end

        def index_name_exists?(_table_name, _index_name, _default)
          false
        end

        # Returns an array of indexes for the given table.
        def indexes(_table_name, _name = nil)
          []
        end

        # Returns the list of all column definitions for a table.
        def columns(table_name)
          column_definitions(table_name.to_s).map do |column_name, type, default, notnull, oid, fmod|
            default_value = extract_value_from_default(default)
            type_metadata = fetch_type_metadata(column_name, type, oid, fmod)
            default_function = extract_default_function(default_value, default)
            new_column(column_name, default_value, type_metadata, !notnull, table_name, default_function)
          end
        end

        def new_column(name, default, sql_type_metadata = nil, null = true, _table_name = nil, default_function = nil) # :nodoc:
          RedshiftColumn.new(name, default, sql_type_metadata, null, default_function)
        end

        # Returns the current database name.
        def current_database
          select_value('select current_database()', 'SCHEMA')
        end

        # Returns the current schema name.
        def current_schema
          select_value('SELECT current_schema', 'SCHEMA')
        end

        # Returns the current database encoding format.
        def encoding
          select_value(
            "SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname LIKE '#{current_database}'", 'SCHEMA'
          )
        end

        def collation; end

        def ctype; end

        # Returns an array of schema names.
        def schema_names
          select_values(<<-SQL, 'SCHEMA')
            SELECT nspname
              FROM pg_namespace
             WHERE nspname !~ '^pg_.*'
               AND nspname NOT IN ('information_schema')
             ORDER by nspname;
          SQL
        end

        # Creates a schema for the given schema name.
        def create_schema(schema_name)
          execute "CREATE SCHEMA #{quote_schema_name(schema_name)}"
        end

        # Drops the schema for the given schema name.
        def drop_schema(schema_name, **options)
          execute "DROP SCHEMA#{' IF EXISTS' if options[:if_exists]} #{quote_schema_name(schema_name)} CASCADE"
        end

        # Sets the schema search path to a string of comma-separated schema names.
        # Names beginning with $ have to be quoted (e.g. $user => '$user').
        # See: http://www.postgresql.org/docs/current/static/ddl-schemas.html
        #
        # This should be not be called manually but set in database.yml.
        def schema_search_path=(schema_csv)
          return unless schema_csv

          execute("SET search_path TO #{schema_csv}", 'SCHEMA')
          @schema_search_path = schema_csv
        end

        # Returns the active schema search path.
        def schema_search_path
          @schema_search_path ||= select_value('SHOW search_path', 'SCHEMA')
        end

        # Returns the sequence name for a table's primary key or some other specified key.
        def default_sequence_name(table_name, pk = "id") # :nodoc:
          result = serial_sequence(table_name, pk)
          return nil unless result

          Utils.extract_schema_qualified_name(result).to_s
        rescue ActiveRecord::StatementInvalid
          Redshift::Name.new(nil, "#{table_name}_#{pk}_seq").to_s
        end

        def serial_sequence(table, column)
          select_value("SELECT pg_get_serial_sequence(#{quote(table)}, #{quote(column)})", 'SCHEMA')
        end

        def set_pk_sequence!(table, value); end

        def reset_pk_sequence!(table, pk = nil, sequence = nil); end

        def pk_and_sequence_for(_table) # :nodoc:
          [nil, nil]
        end

        # Returns just a table's primary key
        def primary_keys(table)
          pks = query(<<-END_SQL, 'SCHEMA')
            SELECT DISTINCT attr.attname
            FROM pg_attribute attr
            INNER JOIN pg_depend dep ON attr.attrelid = dep.refobjid AND attr.attnum = dep.refobjsubid
            INNER JOIN pg_constraint cons ON attr.attrelid = cons.conrelid AND attr.attnum = any(cons.conkey)
            WHERE cons.contype = 'p'
              AND dep.refobjid = '#{quote_table_name(table)}'::regclass
          END_SQL
          pks.present? ? pks[0] : pks
        end

        # Renames a table.
        # Also renames a table's primary key sequence if the sequence name exists and
        # matches the Active Record default.
        #
        # Example:
        #   rename_table('octopuses', 'octopi')
        def rename_table(table_name, new_name)
          clear_cache!
          execute "ALTER TABLE #{quote_table_name(table_name)} RENAME TO #{quote_table_name(new_name)}"
        end

        def add_column(table_name, column_name, type, **options) # :nodoc:
          clear_cache!
          super
        end

        # Changes the column of a table.
        def change_column(table_name, column_name, type, **options)
          clear_cache!
          quoted_table_name = quote_table_name(table_name)
          sql_type = type_to_sql(type, limit: options[:limit], precision: options[:precision], scale: options[:scale])
          sql = "ALTER TABLE #{quoted_table_name} ALTER COLUMN #{quote_column_name(column_name)} TYPE #{sql_type}"
          sql << " USING #{options[:using]}" if options[:using]
          if options[:cast_as]
            sql << " USING CAST(#{quote_column_name(column_name)} AS #{type_to_sql(options[:cast_as],
                                                                                   limit: options[:limit], precision: options[:precision], scale: options[:scale])})"
          end
          execute sql

          change_column_default(table_name, column_name, options[:default]) if options_include_default?(options)
          change_column_null(table_name, column_name, options[:null], options[:default]) if options.key?(:null)
        end

        # Changes the default value of a table column.
        def change_column_default(table_name, column_name, default_or_changes)
          clear_cache!
          column = column_for(table_name, column_name)
          return unless column

          default = extract_new_default_value(default_or_changes)
          alter_column_query = "ALTER TABLE #{quote_table_name(table_name)} ALTER COLUMN #{quote_column_name(column_name)} %s"
          if default.nil?
            # <tt>DEFAULT NULL</tt> results in the same behavior as <tt>DROP DEFAULT</tt>. However, PostgreSQL will
            # cast the default to the columns type, which leaves us with a default like "default NULL::character varying".
            execute alter_column_query % 'DROP DEFAULT'
          else
            execute alter_column_query % "SET DEFAULT #{quote_default_value(default, column)}"
          end
        end

        def change_column_null(table_name, column_name, null, default = nil)
          clear_cache!
          unless null || default.nil?
            column = column_for(table_name, column_name)
            if column
              execute("UPDATE #{quote_table_name(table_name)} SET #{quote_column_name(column_name)}=#{quote_default_value(
                default, column
              )} WHERE #{quote_column_name(column_name)} IS NULL")
            end
          end
          execute("ALTER TABLE #{quote_table_name(table_name)} ALTER #{quote_column_name(column_name)} #{null ? 'DROP' : 'SET'} NOT NULL")
        end

        # Renames a column in a table.
        def rename_column(table_name, column_name, new_column_name) # :nodoc:
          clear_cache!
          execute "ALTER TABLE #{quote_table_name(table_name)} RENAME COLUMN #{quote_column_name(column_name)} TO #{quote_column_name(new_column_name)}"
        end

        def add_index(table_name, column_name, **options); end

        def remove_index!(table_name, index_name); end

        def rename_index(table_name, old_name, new_name); end

        def foreign_keys(table_name)
          fk_info = select_all(<<-SQL.strip_heredoc, 'SCHEMA')
            SELECT t2.relname AS to_table, a1.attname AS column, a2.attname AS primary_key, c.conname AS name, c.confupdtype AS on_update, c.confdeltype AS on_delete
            FROM pg_constraint c
            JOIN pg_class t1 ON c.conrelid = t1.oid
            JOIN pg_class t2 ON c.confrelid = t2.oid
            JOIN pg_attribute a1 ON a1.attnum = c.conkey[1] AND a1.attrelid = t1.oid
            JOIN pg_attribute a2 ON a2.attnum = c.confkey[1] AND a2.attrelid = t2.oid
            JOIN pg_namespace t3 ON c.connamespace = t3.oid
            WHERE c.contype = 'f'
              AND t1.relname = #{quote(table_name)}
              AND t3.nspname = ANY (current_schemas(false))
            ORDER BY c.conname
          SQL

          fk_info.map do |row|
            options = {
              column: row['column'],
              name: row['name'],
              primary_key: row['primary_key']
            }

            options[:on_delete] = extract_foreign_key_action(row['on_delete'])
            options[:on_update] = extract_foreign_key_action(row['on_update'])

            ForeignKeyDefinition.new(table_name, row['to_table'], options)
          end
        end

        FOREIGN_KEY_ACTIONS = {
          'c' => :cascade,
          'n' => :nullify,
          'r' => :restrict
        }.freeze

        def extract_foreign_key_action(specifier)
          FOREIGN_KEY_ACTIONS[specifier]
        end

        def index_name_length
          63
        end

        # Maps logical Rails types to PostgreSQL-specific data types.
        def type_to_sql(type, limit: nil, precision: nil, scale: nil, **)
          case type.to_s
          when 'integer'
            return 'integer' unless limit

            case limit
            when 1, 2 then 'smallint'
            when nil, 3, 4 then 'integer'
            when 5..8 then 'bigint'
            else raise(ActiveRecordError,
                       "No integer type has byte size #{limit}. Use a numeric with precision 0 instead.")
            end
          else
            super
          end
        end

        # PostgreSQL requires the ORDER BY columns in the select list for distinct queries, and
        # requires that the ORDER BY include the distinct column.
        def columns_for_distinct(columns, orders) # :nodoc:
          order_columns = orders.compact_blank.map { |s|
            # Convert Arel node to string
            s = visitor.compile(s) unless s.is_a?(String)
            # Remove any ASC/DESC modifiers
            s.gsub(/\s+(?:ASC|DESC)\b/i, "")
             .gsub(/\s+NULLS\s+(?:FIRST|LAST)\b/i, "")
          }.compact_blank.map.with_index { |column, i| "#{column} AS alias_#{i}" }

          (order_columns << super).join(", ")
        end

        def fetch_type_metadata(column_name, sql_type, oid, fmod)
          cast_type = get_oid_type(oid.to_i, fmod.to_i, column_name, sql_type)
          simple_type = SqlTypeMetadata.new(
            sql_type: sql_type,
            type: cast_type.type,
            limit: cast_type.limit,
            precision: cast_type.precision,
            scale: cast_type.scale
          )
          TypeMetadata.new(simple_type, oid: oid, fmod: fmod)
        end
      end
    end
  end
end
