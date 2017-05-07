# frozen_string_literal: true

require "graphql"
require "graphql/client/schema/enum_type"
require "graphql/client/schema/interface_type"
require "graphql/client/schema/list_type"
require "graphql/client/schema/non_null_type"
require "graphql/client/schema/object_type"
require "graphql/client/schema/scalar_type"
require "graphql/client/schema/union_type"

module GraphQL
  class Client
    module Schema
      def self.generate(schema)
        mod = Module.new
        mod.define_singleton_method :schema do
          schema
        end

        cache = {}
        schema.types.each do |name, type|
          next if name.start_with?("__")
          mod.const_set(name, class_for(schema, type, cache))
        end
        mod
      end

      def self.class_for(schema, type, cache)
        return cache[type] if cache[type]

        case type
        when GraphQL::InputObjectType
          nil
        when GraphQL::ScalarType
          cache[type] = ScalarType.new(type)
        when GraphQL::EnumType
          cache[type] = EnumType.new(type)
        when GraphQL::ListType
          cache[type] = class_for(schema, type.of_type, cache).to_list_type
        when GraphQL::NonNullType
          cache[type] = class_for(schema, type.of_type, cache).to_non_null_type
        when GraphQL::UnionType
          klass = cache[type] = UnionType.new(type)

          type.possible_types.each do |possible_type|
            possible_klass = class_for(schema, possible_type, cache)
            possible_klass.send :include, klass
          end

          klass
        when GraphQL::InterfaceType
          cache[type] = InterfaceType.new(type)
        when GraphQL::ObjectType
          klass = cache[type] = ObjectType.new(type)

          type.interfaces.each do |interface|
            klass.send :include, class_for(schema, interface, cache)
          end

          type.all_fields.each do |field|
            klass.fields[field.name.to_sym] = class_for(schema, field.type, cache)
          end

          klass
        else
          raise TypeError, "unexpected #{type.class}"
        end
      end
    end
  end
end
