# frozen_string_literal: true

require "active_support/core_ext/array/wrap"
require "active_support/core_ext/hash/reverse_merge"
require "active_support/core_ext/object/deep_dup"
require "active_support/core_ext/string/filters"
require "active_support/core_ext/symbol/starts_ends_with"

module ActiveModel
  module SchematizedJson
    extend ActiveSupport::Concern

    module ClassMethods
      # Provides a schema-enforced access object for a JSON attribute. This allows you to assign values
      # directly from the UI as strings, and still have them set with the correct JSON type in the database.
      #
      # Only the three basic JSON types are supported: boolean, integer, and string, plus arrays of one of them.
      # No other nesting. These types can either be set by referring to them by their symbol or by setting a
      # default value. Arrays are declared the same way, with the element type inside: <tt>[:string]</tt> or
      # <tt>["en", "fr"]</tt>. Anything else raises an ArgumentError when the schema is declared.
      #
      # Assigning an array casts its elements, but changing it in place, like <tt>tags << "ruby"</tt>, skips casting.
      # Default values are filled in when the attribute is loaded or assigned.
      #
      # Examples:
      #
      #   class Account < ApplicationRecord
      #     has_json :settings, restrict_creation_to_admins: true, max_invites: 10, greeting: "Hello!"
      #     has_json :flags, beta: false, staff: :boolean
      #     has_json :preferences, locales: ["en"], favorite_ids: [:integer]
      #   end
      #
      #   a = Account.new
      #   a.settings.restrict_creation_to_admins? # => true
      #   a.settings.max_invites = "100" # => Set to integer 100
      #   a.settings = { "restrict_creation_to_admins" => "false", "max_invites" => "500", "greeting" => "goodbye" }
      #   a.settings.greeting # => "goodbye"
      #   a.flags.staff # => nil
      #   a.flags.staff? # => false
      #   a.preferences.locales # => ["en"]
      #   a.preferences.favorite_ids # => []
      #   a.preferences.favorite_ids = ["", "1", "2"] # => Set to [1, 2]
      def has_json(attr, **schema)
        attr_name = attr.to_s
        types = schema.to_h { |key, declaration| [ key.to_s, SchematizedJson.type_for(declaration) ] }
        defaults = schema.to_h { |key, declaration| [ key.to_s, SchematizedJson.default_for(declaration) ] }

        decorate_attributes([ attr ]) do |_name, cast_type|
          ActiveModel::SchematizedJson::SchemaDefaultsType.new(cast_type, defaults)
        end

        define_method(attr) do
          # Plain Active Model attributes without a default start as nil and skip casting, so assign an empty
          # hash to pick up the defaults.
          _write_attribute(attr_name, {}) if attribute(attr_name).nil?

          # No memoization used in order to stay compatible with #reload (and because it's such a thin accessor).
          ActiveModel::SchematizedJson::DataAccessor.new(types, data: attribute(attr_name))
        end

        define_method("#{attr}=") { |data| public_send(attr).assign_data_with_type_casting(data) }
      end

      # Like +has_json+ but each schema key also becomes its own set of accessor methods.
      #
      #   class Account < ApplicationRecord
      #     has_delegated_json :flags, beta: false, staff: :boolean
      #   end
      #
      #   a = Account.new
      #   a.beta? # => false
      #   a.beta = true
      #   a.beta # => true
      def has_delegated_json(attr, **schema)
        has_json attr, **schema

        schema.each_key do |schema_key|
          define_method(schema_key)       { public_send(attr).public_send(schema_key) }
          define_method("#{schema_key}?") { public_send(attr).public_send("#{schema_key}?") }
          define_method("#{schema_key}=") { |value| send(attr).public_send("#{schema_key}=", value) }
        end
      end
    end

    # Types are declared by symbol, like :boolean, or by a default value of that type, like true.
    # Arrays are declared the same way with the element type inside, like [:string] or ["en"].
    def self.type_for(declaration) # :nodoc:
      if declaration.is_a?(Array)
        ArrayType.new(element_type_for(declaration))
      else
        scalar_type_for(declaration)
      end
    end

    def self.element_type_for(array) # :nodoc:
      element_types = array.map { |element| scalar_type_for(element) }.uniq(&:type)

      if element_types.one?
        element_types.first
      else
        raise ArgumentError, 'Arrays must declare a single element type, like [:string] or ["en", "fr"]'
      end
    end

    def self.scalar_type_for(declaration) # :nodoc:
      case declaration
      when :boolean, :integer, :string
        ActiveModel::Type.lookup declaration
      when true, false
        ActiveModel::Type.lookup :boolean
      when Integer
        ActiveModel::Type.lookup :integer
      when String
        ActiveModel::Type.lookup :string
      when Hash
        raise ArgumentError, "Nested objects are not supported in JSON schemas"
      else
        raise ArgumentError, "Only boolean, integer, or strings are allowed as JSON schema types"
      end
    end

    # Types declared by symbol have no default, except arrays, which start out empty so they can be appended to.
    def self.default_for(declaration) # :nodoc:
      case declaration
      when Array
        declaration.any?(Symbol) ? [] : declaration
      when Symbol
        nil
      else
        declaration
      end
    end

    # :nodoc:
    class ArrayType
      def initialize(element_type)
        @element_type = element_type
      end

      # Blank strings are dropped, since form helpers like +collection_check_boxes+ submit one with every array.
      def cast(value)
        unless value.nil?
          Array.wrap(value).reject { |element| blank_element?(element) }.map { |element| @element_type.cast(element) }
        end
      end

      private
        def blank_element?(element)
          element.nil? || (element.is_a?(String) && element.blank?)
        end
    end

    # :nodoc:
    class DataAccessor
      def initialize(types, data:)
        @types, @data = types, data
      end

      def assign_data_with_type_casting(new_data)
        new_data.each { |k, v| public_send "#{k}=", v }
      end

      private
        def method_missing(method_name, *args, **kwargs)
          key = method_name.to_s.remove(/(\?|=)/)

          if @types.key? key
            if method_name.ends_with?("?")
              @data[key].present?
            elsif method_name.ends_with?("=")
              @data[key] = @types[key].cast(args.first)
            else
              @data[key]
            end
          else
            super
          end
        end

        def respond_to_missing?(method_name, include_private = false)
          @types.key?(method_name.to_s.remove(/[?=]/)) || super
        end
    end

    # :nodoc:
    class SchemaDefaultsType < ActiveSupport::Delegation::DelegateClass(ActiveModel::Type::Value)
      def initialize(cast_type, defaults)
        super(cast_type)
        @defaults = defaults
      end

      def cast(value)
        with_defaults(super)
      end

      def deserialize(value)
        with_defaults(super)
      end

      # Defaults alone never count as a change, so compare against the stored value with defaults applied.
      def changed_in_place?(raw_old_value, new_value)
        super && deserialize(raw_old_value) != new_value
      end

      private
        # Anything other than an object, like legacy data or a serialized string, is left alone.
        def with_defaults(value)
          if value.nil? || value.is_a?(Hash)
            (value || {}).reverse_merge(@defaults.deep_dup)
          else
            value
          end
        end
    end
  end
end
