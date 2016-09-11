require "active_support/inflector"
require "active_support/notifications"
require "graphql"
require "graphql/client/error"
require "graphql/client/query_result"
require "graphql/client/query"
require "graphql/client/response"
require "graphql/language/nodes/deep_freeze_ext"
require "graphql/language/operation_slice"

module GraphQL
  class Client
    class ValidationError < Error; end

    attr_reader :schema, :fetch

    attr_accessor :document_tracking_enabled

    def self.load_schema(schema)
      case schema
      when GraphQL::Schema
        schema
      when Hash
        GraphQL::Schema::Loader.load(schema)
      when String
        if schema.end_with?(".json")
          load_schema(File.read(schema))
        else
          load_schema(JSON.parse(schema))
        end
      end
    end

    def initialize(schema: nil, fetch: nil)
      @schema = self.class.load_schema(schema)
      @fetch = fetch
      @document = GraphQL::Language::Nodes::Document.new(definitions: [])
      @document_tracking_enabled = false
    end

    class Definition < Module
      def self.for(node:, **kargs)
        case node
        when Language::Nodes::OperationDefinition
          OperationDefinition.new(node: node, **kargs)
        when Language::Nodes::FragmentDefinition
          FragmentDefinition.new(node: node, **kargs)
        else
          raise TypeError, "expected node to be a definition type, but was #{node.class}"
        end
      end

      def initialize(node:, document:)
        @definition_node = node
        @document = document
      end

      # Internal: Get underlying operation or fragment defintion AST node for
      # definition.
      #
      # Returns OperationDefinition or FragmentDefinition object.
      attr_reader :definition_node

      # Public: Global name of definition in client document.
      #
      # Returns a GraphQL safe name of the Ruby constant String.
      #
      #   "Users::UserQuery" #=> "Users__UserQuery"
      #
      # Returns String.
      def definition_name
        return @definition_name if defined?(@definition_name)

        if name
          @definition_name = name.gsub("::", "__").freeze
        else
          "#{self.class.name}_#{object_id}".gsub("::", "__").freeze
        end
      end

      # Public: Get document with only the definitions needed to perform this
      # operation.
      #
      # Returns GraphQL::Language::Nodes::Document with one OperationDefinition
      # and any FragmentDefinition dependencies.
      attr_reader :document

      def new(*args)
        query_result_class.new(*args)
      end

      private

      def query_result_class
        @query_result_class ||= GraphQL::Client::QueryResult.wrap(definition_node, name: name)
      end
    end

    class OperationDefinition < Definition
      # Public: Alias for definition name.
      alias operation_name definition_name
    end

    class FragmentDefinition < Definition
    end

    def parse(str, filename = nil, lineno = nil)
      if filename.nil? || lineno.nil?
        filename, lineno, = caller(1, 1).first.split(":", 3)
        lineno = lineno.to_i
      end

      definition_dependencies = Set.new

      str = str.gsub(/\.\.\.([a-zA-Z0-9_]+(::[a-zA-Z0-9_]+)+)/) do
        match = Regexp.last_match
        const_name = match[1]
        case fragment = ActiveSupport::Inflector.safe_constantize(const_name)
        when FragmentDefinition
          definition_dependencies.merge(fragment.document.definitions)
          "...#{fragment.definition_name}"
        else
          if fragment
            error = TypeError.new("expected #{const_name} to be a #{FragmentDefinition}, but was a #{fragment.class}")
          else
            error = NameError.new("uninitialized constant #{const_name}")
          end

          if filename && lineno
            error.set_backtrace(["#{filename}:#{lineno + match.pre_match.count("\n") + 1}"] + caller)
          end

          raise error
        end
      end

      doc = GraphQL.parse(str)

      doc.definitions.each do |node|
        node.name ||= "__anonymous__"
      end

      document_dependencies = Language::Nodes::Document.new(definitions: doc.definitions + definition_dependencies.to_a)

      if @schema
        rules = GraphQL::StaticValidation::ALL_RULES - [GraphQL::StaticValidation::FragmentsAreUsed]
        validator = GraphQL::StaticValidation::Validator.new(schema: @schema, rules: rules)
        query = GraphQL::Query.new(@schema, document: document_dependencies)

        errors = validator.validate(query)
        errors.fetch(:errors).each do |error|
          validation_line = error["locations"][0]["line"]
          error = ValidationError.new(error["message"])
          error.set_backtrace(["#{filename}:#{lineno + validation_line}"] + caller) if filename && lineno
          raise error
        end
      end

      definitions = {}
      doc.definitions.each do |node|
        node.name = nil if node.name == "__anonymous__"
        sliced_document = Language::OperationSlice.slice(document_dependencies, node.name)
        definition = Definition.for(node: node, document: sliced_document)
        definitions[node.name] = definition
      end

      rename_node = ->(node, _parent) do
        definition = definitions[node.name]
        if definition
          node.extend(LazyName)
          node.name = -> { definition.definition_name }
        end
      end
      visitor = Language::Visitor.new(doc)
      visitor[Language::Nodes::FragmentDefinition].leave << rename_node
      visitor[Language::Nodes::OperationDefinition].leave << rename_node
      visitor[Language::Nodes::FragmentSpread].leave << rename_node
      visitor.visit

      doc.deep_freeze

      document.definitions.concat(doc.definitions) if document_tracking_enabled

      if definitions[nil]
        definitions[nil]
      else
        Module.new do
          definitions.each do |name, definition|
            const_set(name, definition)
          end
        end
      end
    end

    attr_reader :document

    def query(definition, variables: {}, context: {})
      raise Error, "client network fetching not configured" unless fetch

      query = Query.new(definition.document,
                        operation_name: definition.operation_name,
                        variables: variables,
                        context: context)

      result = ActiveSupport::Notifications.instrument("query.graphql", query.payload) do
        fetch.call(query)
      end

      data, errors, extensions = result.values_at("data", "errors", "extensions")

      if data && errors
        PartialResponse.new(
          data: definition.new(data),
          errors: ResponseErrors.new(definition, errors),
          extensions: extensions
        )
      elsif data && !errors
        SuccessfulResponse.new(
          data: definition.new(data),
          extensions: extensions
        )
      elsif !data && errors
        FailedResponse.new(
          errors: ResponseErrors.new(definition, errors),
          extensions: extensions
        )
      else
        raise Error, "invalid GraphQL response, expected data or errors"
      end
    end

    IntrospectionDocument = GraphQL.parse(GraphQL::Introspection::INTROSPECTION_QUERY).deep_freeze
    IntrospectionQuery = Query.new(IntrospectionDocument)

    def fetch_schema
      fetch.call(IntrospectionQuery)
    end

    module LazyName
      def name
        @name.call
      end
    end
  end
end
